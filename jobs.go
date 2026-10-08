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
	Title     string           `json:"title"`
	Status    Status           `json:"status"`
	Percent   float64          `json:"percent"` // progress of the current stage
	Speed     string           `json:"speed,omitempty"`
	ETA       string           `json:"eta,omitempty"`
	Error     string           `json:"error,omitempty"`
	Outputs   []string         `json:"outputs,omitempty"`
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

func newQueue(dir string, t *tools) (*queue, error) {
	if err := os.MkdirAll(filepath.Join(dir, "tmp"), 0o755); err != nil {
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
		case StQueued:
			// stays queued and resumes
		}
	}
	// Leftover work dirs belong to jobs that no longer exist.
	if es, err := os.ReadDir(filepath.Join(dir, "tmp")); err == nil {
		for _, e := range es {
			_ = os.RemoveAll(filepath.Join(dir, "tmp", e.Name()))
		}
	}
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
	if !strings.HasPrefix(j.URL, "http://") && !strings.HasPrefix(j.URL, "https://") {
		return errors.New("url must start with http:// or https://")
	}
	if _, err := j.Download.args(); err != nil {
		return err
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

	work := filepath.Join(q.dir, "tmp", j.ID)
	defer os.RemoveAll(work)
	err := q.pipeline(ctx, j, work)

	q.mu.Lock()
	defer q.mu.Unlock()
	switch {
	case err == nil:
		q.finishLocked(j, StDone, "")
	case ctx.Err() != nil:
		q.finishLocked(j, StCanceled, "")
	default:
		q.finishLocked(j, StFailed, err.Error())
	}
}

func (q *queue) pipeline(ctx context.Context, j *Job, work string) error {
	for _, n := range []string{toolYtdlp, toolFfmpeg} {
		if !q.tools.installed(n) {
			return fmt.Errorf("%s is not installed (Tools panel)", n)
		}
	}
	transcode := !j.Transcode.Skip && !j.Download.AudioOnly
	if transcode && !q.tools.installed(toolHandbrake) {
		return errors.New("HandBrakeCLI is not installed (Tools panel)")
	}
	if err := os.MkdirAll(j.Output.Dir, 0o755); err != nil {
		return fmt.Errorf("output folder: %w", err)
	}
	if err := os.MkdirAll(work, 0o755); err != nil {
		return err
	}

	files, err := q.download(ctx, j, work)
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return errors.New("yt-dlp finished but reported no output file")
	}
	var outs []string
	for i, src := range files {
		final := src
		if transcode {
			if final, err = q.transcode(ctx, j, src, work); err != nil {
				return err
			}
		}
		q.update(j, false, func(j *Job) { j.Status, j.Percent, j.Speed, j.ETA = StMoving, 100, "", "" })
		name := j.Output.Filename
		if name == "" || len(files) > 1 {
			name = strings.TrimSuffix(filepath.Base(src), filepath.Ext(src))
			if j.Title != "" && j.Title != j.URL && len(files) == 1 {
				name = j.Title
			}
		} else if i > 0 {
			name = fmt.Sprintf("%s %d", name, i+1)
		}
		dst, err := moveInto(final, j.Output.Dir, sanitize(name), j.Output.Overwrite)
		if err != nil {
			return err
		}
		outs = append(outs, dst)
		if transcode && j.Output.KeepSource {
			sdst, err := moveInto(src, j.Output.Dir, sanitize(name)+" (source)", j.Output.Overwrite)
			if err != nil {
				return err
			}
			outs = append(outs, sdst)
		}
	}
	q.update(j, false, func(j *Job) { j.Outputs = outs })
	return nil
}

var unsafeName = regexp.MustCompile(`[/:\x00-\x1f]`)

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
	cmd.Cancel = func() error { return cmd.Process.Signal(os.Interrupt) }
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
	return dst, nil
}
