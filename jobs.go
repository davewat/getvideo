package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Status string

const (
	StQueued      Status = "queued"
	StDownloading Status = "downloading"
	StTranscoding Status = "transcoding"
	StMoving      Status = "moving"
	StDone        Status = "done"
	StFailed      Status = "failed"
	StCanceled    Status = "canceled"
)

const maxLogLines = 400

// Job is one URL's trip through download -> transcode -> move.
type Job struct {
	ID        string           `json:"id"`
	URL       string           `json:"url"`
	Source    string           `json:"source,omitempty"` // a file on this computer to edit with HandBrake, instead of a download
	Title     string           `json:"title"`
	Status    Status           `json:"status"`
	Percent   float64          `json:"percent"` // progress of the current stage
	Speed     string           `json:"speed,omitempty"`
	ETA       string           `json:"eta,omitempty"`
	Error     string           `json:"error,omitempty"`
	Outputs   []string         `json:"outputs,omitempty"`
	Downloads []string         `json:"downloads,omitempty"` // downloaded files kept for a conversion that has not finished
	Log       []string         `json:"log"`
	Download  DownloadOptions  `json:"download"`
	Transcode TranscodeOptions `json:"transcode"`
	Output    OutputOptions    `json:"output"`
	Created   time.Time        `json:"created"`
	Finished  *time.Time       `json:"finished,omitempty"`
}

type queue struct {
	dir   string
	tools *tools

	mu     sync.Mutex
	jobs   []*Job
	cancel map[string]context.CancelFunc
	subs   map[chan []byte]struct{}
	lastTx map[string]time.Time

	wake chan struct{}
	stop chan struct{}
}

// workPrefix starts the name of a job's temporary folder inside its working folder.
const workPrefix = ".getvideo-"

// workDirFor is where one job's temporary files live: a hidden folder inside the working folder
// the video is saved to. yt-dlp downloads there and HandBrake converts there, so the finished file
// is moved a few inches (a rename on the same disk, never a copy) and a download never fills the
// system disk when the working folder is on a bigger drive.
func workDirFor(j *Job) string { return filepath.Join(j.Output.Dir, workPrefix+j.ID) }

// keepsDownload is true when a failed or canceled job leaves its downloaded file in the working
// folder, so "Try again" continues from the conversion instead of downloading again.
func keepsDownload(j *Job) bool {
	return j.Source == "" && j.Download.KeepDownload && !j.Transcode.Skip && !j.Download.AudioOnly
}

// discardWork empties a job's temporary folder. When the job keeps its download only HandBrake's
// half-written output goes; everything else stays so the job can continue.
func discardWork(j *Job) {
	work := workDirFor(j)
	if !keepsDownload(j) {
		_ = os.RemoveAll(work)
		return
	}
	if outs, _ := filepath.Glob(filepath.Join(work, "out.*")); len(outs) > 0 {
		for _, f := range outs {
			_ = os.Remove(f)
		}
	}
	_ = os.Remove(work) // only succeeds when nothing is left in it
}

func newQueue(dir string, t *tools) (*queue, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	q := &queue{
		dir: dir, tools: t,
		cancel: map[string]context.CancelFunc{},
		subs:   map[chan []byte]struct{}{},
		lastTx: map[string]time.Time{},
		wake:   make(chan struct{}, 1),
		stop:   make(chan struct{}),
	}
	if b, err := os.ReadFile(filepath.Join(dir, "jobs.json")); err == nil {
		_ = json.Unmarshal(b, &q.jobs)
	}
	for _, j := range q.jobs {
		switch j.Status {
		case StDownloading, StTranscoding, StMoving:
			j.Status, j.Error = StFailed, "interrupted by restart"
			discardWork(j) // what it left behind in its working folder
		case StQueued:
			// stays queued and resumes
		}
	}
	// Earlier versions kept temporary files here instead of in the working folder.
	_ = os.RemoveAll(filepath.Join(dir, "tmp"))
	go q.run()
	q.poke()
	return q, nil
}

func (q *queue) shutdown() {
	close(q.stop)
	q.mu.Lock()
	for _, c := range q.cancel {
		c()
	}
	q.mu.Unlock()
}

func (q *queue) poke() {
	select {
	case q.wake <- struct{}{}:
	default:
	}
}

// persist writes jobs.json; callers hold q.mu.
func (q *queue) persist() {
	b, err := json.MarshalIndent(q.jobs, "", " ")
	if err != nil {
		return
	}
	tmp := filepath.Join(q.dir, "jobs.json.tmp")
	if os.WriteFile(tmp, b, 0o644) == nil {
		_ = os.Rename(tmp, filepath.Join(q.dir, "jobs.json"))
	}
}

// publish sends the job's snapshot to every SSE subscriber; callers hold q.mu.
func (q *queue) publish(j *Job) {
	b, _ := json.Marshal(j)
	for ch := range q.subs {
		select {
		case ch <- b:
		default: // slow client; it resyncs on its next event
		}
	}
}

func (q *queue) subscribe() (chan []byte, func()) {
	ch := make(chan []byte, 64)
	q.mu.Lock()
	q.subs[ch] = struct{}{}
	q.mu.Unlock()
	return ch, func() { q.mu.Lock(); delete(q.subs, ch); q.mu.Unlock() }
}

func (q *queue) list() []*Job {
	q.mu.Lock()
	defer q.mu.Unlock()
	out := make([]*Job, len(q.jobs))
	for i, j := range q.jobs {
		c := *j
		c.Log = append([]string(nil), j.Log...)
		out[i] = &c
	}
	return out
}

func newID() string { return strconv.FormatInt(time.Now().UnixNano(), 36) }

func (q *queue) add(j *Job) error {
	if j.Source != "" {
		// A file already on disk: HandBrake edits it, with no download. The original is never changed.
		path, err := checkSource(j.Source)
		if err != nil {
			return err
		}
		j.Source, j.URL = path, ""
		j.Download.AudioOnly, j.Download.KeepDownload, j.Transcode.Skip = false, false, false
	} else {
		if !strings.HasPrefix(j.URL, "http://") && !strings.HasPrefix(j.URL, "https://") {
			return errors.New("url must start with http:// or https://")
		}
		if _, err := j.Download.args(); err != nil {
			return err
		}
	}
	if _, err := j.Transcode.args(); err != nil {
		return err
	}
	if j.Output.Dir == "" {
		home, _ := os.UserHomeDir()
		j.Output.Dir = filepath.Join(home, "Downloads")
	}
	j.ID, j.Status, j.Created, j.Log = newID(), StQueued, time.Now(), []string{}
	j.Title = j.URL
	if j.Source != "" {
		j.Title = filepath.Base(j.Source)
	}
	q.mu.Lock()
	q.jobs = append(q.jobs, j)
	q.persist()
	q.publish(j)
	q.mu.Unlock()
	q.poke()
	return nil
}

func (q *queue) find(id string) *Job {
	for _, j := range q.jobs {
		if j.ID == id {
			return j
		}
	}
	return nil
}

func (q *queue) cancelJob(id string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	j := q.find(id)
	if j == nil {
		return false
	}
	if c, ok := q.cancel[id]; ok {
		c()
	} else if j.Status == StQueued {
		q.finishLocked(j, StCanceled, "")
	}
	return true
}

func (q *queue) retry(id string) bool {
	q.mu.Lock()
	j := q.find(id)
	ok := j != nil && (j.Status == StFailed || j.Status == StCanceled)
	if ok {
		j.Status, j.Error, j.Percent, j.Speed, j.ETA, j.Finished = StQueued, "", 0, "", "", nil
		j.Log = j.Log[:0]
		q.persist()
		q.publish(j)
	}
	q.mu.Unlock()
	if ok {
		q.poke()
	}
	return ok
}

func (q *queue) remove(id string) bool {
	q.mu.Lock()
	defer q.mu.Unlock()
	for i, j := range q.jobs {
		if j.ID == id {
			if _, running := q.cancel[id]; running {
				return false
			}
			q.jobs = append(q.jobs[:i], q.jobs[i+1:]...)
			_ = os.RemoveAll(workDirFor(j)) // a kept download goes with the job
			q.persist()
			b, _ := json.Marshal(map[string]string{"id": id, "removed": "true"})
			for ch := range q.subs {
				select {
				case ch <- b:
				default:
				}
			}
			return true
		}
	}
	return false
}

func (q *queue) finishLocked(j *Job, st Status, errMsg string) {
	now := time.Now()
	j.Status, j.Error, j.Finished = st, errMsg, &now
	j.Speed, j.ETA = "", ""
	if st == StDone {
		j.Percent = 100
	}
	q.persist()
	q.publish(j)
}

// update mutates a job under the lock and publishes it. Progress ticks are throttled.
func (q *queue) update(j *Job, throttle bool, f func(*Job)) {
	q.mu.Lock()
	defer q.mu.Unlock()
	f(j)
	if throttle {
		if time.Since(q.lastTx[j.ID]) < 250*time.Millisecond {
			return
		}
		q.lastTx[j.ID] = time.Now()
	}
	q.publish(j)
}

func (q *queue) logLine(j *Job, line string) {
	q.update(j, true, func(j *Job) {
		j.Log = append(j.Log, line)
		if len(j.Log) > maxLogLines {
			j.Log = j.Log[len(j.Log)-maxLogLines:]
		}
	})
}

// run processes queued jobs one at a time, oldest first.
func (q *queue) run() {
	for {
		var next *Job
		q.mu.Lock()
		for _, j := range q.jobs {
			if j.Status == StQueued {
				next = j
				break
			}
		}
		q.mu.Unlock()
		if next == nil {
			select {
			case <-q.wake:
				continue
			case <-q.stop:
				return
			}
		}
		select {
		case <-q.stop:
			return
		default:
		}
		q.process(next)
	}
}

func (q *queue) process(j *Job) {
	ctx, cancel := context.WithCancel(context.Background())
	q.mu.Lock()
	q.cancel[j.ID] = cancel
	q.mu.Unlock()
	defer func() {
		cancel()
		q.mu.Lock()
		delete(q.cancel, j.ID)
		delete(q.lastTx, j.ID)
		q.mu.Unlock()
	}()

	work := workDirFor(j)
	err := q.pipeline(ctx, j, work)
	if err == nil {
		_ = os.RemoveAll(work)
	} else {
		discardWork(j) // keeps the download for "Try again" when the job asked for that
	}

	q.mu.Lock()
	defer q.mu.Unlock()
	if err == nil {
		j.Downloads = nil
	}
	switch {
	case err == nil:
		q.finishLocked(j, StDone, "")
	case ctx.Err() != nil:
		q.finishLocked(j, StCanceled, "")
	default:
		q.finishLocked(j, StFailed, err.Error())
	}
}

// checkSource turns what the user gave into the absolute path of a file that exists.
func checkSource(path string) (string, error) {
	if strings.HasPrefix(path, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			path = filepath.Join(home, path[2:])
		}
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	st, err := os.Stat(abs)
	switch {
	case err != nil:
		return "", fmt.Errorf("cannot find the file %s", abs)
	case st.IsDir():
		return "", fmt.Errorf("%s is a folder, not a video file", abs)
	}
	return abs, nil
}

func (q *queue) pipeline(ctx context.Context, j *Job, work string) error {
	local := j.Source != ""
	if !local {
		for _, n := range []string{toolYtdlp, toolFfmpeg} {
			if !q.tools.installed(n) {
				return fmt.Errorf("%s is not installed (Tools panel)", n)
			}
		}
	}
	transcode := local || (!j.Transcode.Skip && !j.Download.AudioOnly)
	if transcode && !q.tools.installed(toolHandbrake) {
		return errors.New("HandBrakeCLI is not installed (Tools panel)")
	}
	if err := os.MkdirAll(j.Output.Dir, 0o755); err != nil {
		return fmt.Errorf("working folder: %w", err)
	}
	if err := os.MkdirAll(work, 0o755); err != nil {
		return fmt.Errorf("working folder: %w", err)
	}

	var files []string
	if local {
		if _, err := checkSource(j.Source); err != nil {
			return err
		}
		files = []string{j.Source}
		q.logLine(j, "Editing "+j.Source+" with HandBrake. The original file is not changed.")
	} else if files = keptDownloads(j); files != nil {
		q.logLine(j, "Using the download kept from last time; going straight to the conversion.")
	} else {
		var err error
		if files, err = q.download(ctx, j, work); err != nil {
			return err
		}
		if len(files) == 0 {
			return errors.New("yt-dlp finished but reported no output file")
		}
		if keepsDownload(j) { // tracked in the job (and saved), so it survives a crash or a quit
			q.update(j, false, func(j *Job) { j.Downloads = files })
			q.mu.Lock()
			q.persist()
			q.mu.Unlock()
		}
	}
	var outs []string
	for i, src := range files {
		final := src
		if transcode {
			var err error
			if final, err = q.transcode(ctx, j, src, work); err != nil {
				return err
			}
		}
		q.update(j, false, func(j *Job) { j.Status, j.Percent, j.Speed, j.ETA = StMoving, 100, "", "" })
		name := j.Output.Filename
		overwrite := j.Output.Overwrite
		if local {
			if name == "" {
				name = strings.TrimSuffix(filepath.Base(src), filepath.Ext(src)) + " (edited)"
			}
			// Never write over the file being edited, whatever the settings say.
			if same(filepath.Join(j.Output.Dir, sanitize(name)+filepath.Ext(final)), src) {
				overwrite = false
			}
		} else if name == "" || len(files) > 1 {
			name = strings.TrimSuffix(filepath.Base(src), filepath.Ext(src))
			if j.Title != "" && j.Title != j.URL && len(files) == 1 {
				name = j.Title
			}
		} else if i > 0 {
			name = fmt.Sprintf("%s %d", name, i+1)
		}
		dst, err := moveInto(final, j.Output.Dir, sanitize(name), overwrite)
		if err != nil {
			return err
		}
		outs = append(outs, dst)
		if transcode && !local && j.Output.KeepSource {
			sdst, err := moveInto(src, j.Output.Dir, sanitize(name)+" (source)", j.Output.Overwrite)
			if err != nil {
				return err
			}
			outs = append(outs, sdst)
		}
		// This file is finished: it is no longer waiting for a conversion.
		q.update(j, false, func(j *Job) { j.Downloads = withoutPath(j.Downloads, src) })
	}
	q.update(j, false, func(j *Job) { j.Outputs = outs })
	return nil
}

// keptDownloads returns the downloads a previous attempt left behind, or nil when there are none
// or any of them has gone, in which case the video is downloaded again.
func keptDownloads(j *Job) []string {
	if len(j.Downloads) == 0 {
		return nil
	}
	for _, p := range j.Downloads {
		if st, err := os.Stat(p); err != nil || st.IsDir() {
			return nil
		}
	}
	return append([]string(nil), j.Downloads...)
}

// same reports whether two paths are the same file on disk.
func same(a, b string) bool {
	sa, errA := os.Stat(a)
	sb, errB := os.Stat(b)
	if errA != nil || errB != nil {
		return filepath.Clean(a) == filepath.Clean(b)
	}
	return os.SameFile(sa, sb)
}

func withoutPath(paths []string, p string) []string {
	var out []string
	for _, x := range paths {
		if x != p {
			out = append(out, x)
		}
	}
	return out
}

// unsafeName covers what macOS, Linux and Windows each refuse in a file name.
var unsafeName = regexp.MustCompile(`[/\\:*?"<>|\x00-\x1f]`)

func sanitize(s string) string {
	s = strings.TrimSpace(unsafeName.ReplaceAllString(s, "-"))
	s = strings.TrimLeft(s, ".")
	if s == "" {
		s = "video"
	}
	if len(s) > 180 {
		s = s[:180]
	}
	return s
}

// moveInto moves src to dir/name+ext, picking "name (n).ext" when taken unless overwrite is set.
func moveInto(src, dir, name string, overwrite bool) (string, error) {
	ext := filepath.Ext(src)
	dst := filepath.Join(dir, name+ext)
	if !overwrite {
		for n := 1; ; n++ {
			if _, err := os.Stat(dst); os.IsNotExist(err) {
				break
			}
			dst = filepath.Join(dir, fmt.Sprintf("%s (%d)%s", name, n, ext))
		}
	}
	if err := os.Rename(src, dst); err == nil {
		return dst, nil
	}
	if err := copyFile(src, dst); err != nil {
		return "", fmt.Errorf("move to %s: %w", dst, err)
	}
	_ = os.Remove(src)
	return dst, nil
}

// scanLines splits on \n or \r so HandBrake's carriage-return progress is seen live.
func scanLines(r io.Reader, f func(string)) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	sc.Split(func(data []byte, atEOF bool) (int, []byte, error) {
		if atEOF && len(data) == 0 {
			return 0, nil, nil
		}
		if i := bytes.IndexAny(data, "\r\n"); i >= 0 {
			return i + 1, data[:i], nil
		}
		if atEOF {
			return len(data), data, nil
		}
		return 0, nil, nil
	})
	for sc.Scan() {
		if s := strings.TrimSpace(sc.Text()); s != "" {
			f(s)
		}
	}
}

// runCmd runs a process, feeding merged stdout+stderr lines to onLine.
func runCmd(ctx context.Context, bin string, args []string, onLine func(string)) error {
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Cancel = func() error { return interrupt(cmd.Process) }
	cmd.WaitDelay = 5 * time.Second
	pr, pw := io.Pipe()
	cmd.Stdout, cmd.Stderr = pw, pw
	done := make(chan struct{})
	go func() { scanLines(pr, onLine); close(done) }()
	err := cmd.Run()
	pw.Close()
	<-done
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return err
}

func (q *queue) download(ctx context.Context, j *Job, work string) ([]string, error) {
	opts, _ := j.Download.args()
	args := []string{
		"--ffmpeg-location", q.tools.path(toolFfmpeg),
		"--no-colors", "--newline", "--progress",
		"--progress-template", "download:GVPROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
		"--print", "before_dl:GVTITLE %(title)s",
		"--print", "after_move:GVFILE %(filepath)s",
		"-P", work, "-o", "%(id)s.%(ext)s",
	}
	args = append(args, opts...)
	args = append(args, j.URL)

	q.update(j, false, func(j *Job) { j.Status, j.Percent = StDownloading, 0 })
	var files []string
	err := runCmd(ctx, q.tools.path(toolYtdlp), args, func(l string) {
		switch {
		case strings.HasPrefix(l, "GVPROG "):
			f := strings.Split(strings.TrimPrefix(l, "GVPROG "), "|")
			if len(f) == 3 {
				pct, _ := strconv.ParseFloat(strings.TrimSuffix(strings.TrimSpace(f[0]), "%"), 64)
				q.update(j, true, func(j *Job) {
					j.Percent, j.Speed, j.ETA = pct, strings.TrimSpace(f[1]), strings.TrimSpace(f[2])
				})
			}
		case strings.HasPrefix(l, "GVTITLE "):
			title := strings.TrimPrefix(l, "GVTITLE ")
			q.update(j, false, func(j *Job) { j.Title = title })
		case strings.HasPrefix(l, "GVFILE "):
			files = append(files, strings.TrimPrefix(l, "GVFILE "))
		default:
			q.logLine(j, l)
		}
	})
	if err != nil {
		return nil, fmt.Errorf("yt-dlp: %w", err)
	}
	return files, nil
}

// scanLength asks HandBrake how long a video is.
func (q *queue) scanLength(ctx context.Context, src string) (float64, error) {
	var out strings.Builder
	err := runCmd(ctx, q.tools.path(toolHandbrake), []string{"-i", src, "--scan"}, func(l string) { out.WriteString(l + "\n") })
	if err != nil {
		return 0, fmt.Errorf("HandBrakeCLI could not read the video's length: %w", err)
	}
	d, ok := scanDuration(out.String())
	if !ok {
		return 0, errors.New("HandBrakeCLI did not report the video's length, so it cannot be shortened")
	}
	return d, nil
}

var hbProgress = regexp.MustCompile(`Encoding: task \d+ of \d+, ([\d.]+) %(?: \(([\d.]+) fps, avg [\d.]+ fps, ETA (\S+)\))?`)

func (q *queue) transcode(ctx context.Context, j *Job, src, work string) (string, error) {
	opts, _ := j.Transcode.args()
	t := j.Transcode
	if t.Container == "" {
		t.Container = "mp4"
		opts = append([]string{"-f", "av_mp4"}, opts...)
	}
	dst := filepath.Join(work, "out."+t.Container)
	args := append([]string{"-i", src, "-o", dst}, opts...)
	if t.TrimMode != "" {
		var total float64
		if t.needsScan() {
			var err error
			if total, err = q.scanLength(ctx, src); err != nil {
				return "", err
			}
		}
		if start, length, ok := t.trimWindow(total); ok {
			args = append(args, trimArgs(start, length)...)
			q.logLine(j, fmt.Sprintf("Shortening to %s, starting at %s.", clockString(length), clockString(start)))
		} else {
			q.logLine(j, "The video is already no longer than the length asked for; keeping all of it.")
		}
	}

	q.update(j, false, func(j *Job) { j.Status, j.Percent, j.Speed, j.ETA = StTranscoding, 0, "", "" })
	err := runCmd(ctx, q.tools.path(toolHandbrake), args, func(l string) {
		if m := hbProgress.FindStringSubmatch(l); m != nil {
			pct, _ := strconv.ParseFloat(m[1], 64)
			q.update(j, true, func(j *Job) {
				j.Percent, j.ETA = pct, m[3]
				if m[2] != "" {
					j.Speed = m[2] + " fps"
				}
			})
			return
		}
		if strings.HasPrefix(l, "Encoding:") {
			return
		}
		q.logLine(j, l)
	})
	if err != nil {
		return "", fmt.Errorf("HandBrakeCLI: %w", err)
	}
	// HandBrake can finish normally without writing anything, for instance when it does not
	// understand an option. (2026-10-09: this surfaced as "move ...: no such file or directory".)
	if st, err := os.Stat(dst); err != nil || st.Size() == 0 {
		return "", errors.New("HandBrakeCLI finished without creating a video. Check the Convert settings, especially any extra arguments, and see the log.")
	}
	return dst, nil
}
