//go:build !windows

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Stand-ins for the three tools: yt-dlp writes a small file; HandBrake fails until a marker file
// exists, then succeeds. Each call is counted so a test can tell whether yt-dlp ran again.
const fakeYtdlp = `#!/bin/sh
dir=.
while [ $# -gt 0 ]; do case "$1" in -P) dir="$2"; shift;; esac; shift; done
echo x >> "$FAKE_CALLS.ytdlp"
echo "GVTITLE Fake Video"
printf video > "$dir/fake.mp4"
echo "GVFILE $dir/fake.mp4"
`

const fakeHandbrake = `#!/bin/sh
out=
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; esac; shift; done
echo x >> "$FAKE_CALLS.hb"
if [ -f "$FAKE_CALLS.nooutput" ]; then echo "usage: HandBrakeCLI ..." >&2; exit 0; fi
if [ ! -f "$FAKE_CALLS.ok" ]; then printf partial > "$out"; echo "simulated crash" >&2; exit 3; fi
printf converted > "$out"
`

type fakeEnv struct {
	q      *queue
	folder string
	calls  string
}

func newFakeEnv(t *testing.T) *fakeEnv {
	t.Helper()
	data := t.TempDir()
	bin := filepath.Join(data, "bin")
	tl, err := newTools(bin)
	if err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{toolYtdlp: fakeYtdlp, toolHandbrake: fakeHandbrake, toolFfmpeg: "#!/bin/sh\n"} {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	calls := filepath.Join(t.TempDir(), "calls")
	t.Setenv("FAKE_CALLS", calls)
	q, err := newQueue(data, tl)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(q.shutdown)
	return &fakeEnv{q: q, folder: t.TempDir(), calls: calls}
}

func (e *fakeEnv) count(tool string) int {
	b, _ := os.ReadFile(e.calls + "." + tool)
	return len(b) / 2
}

func (e *fakeEnv) wait(t *testing.T, want Status) *Job {
	t.Helper()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(20 * time.Millisecond) {
		if js := e.q.list(); len(js) == 1 && js[0].Status == want {
			return js[0]
		}
	}
	t.Fatalf("timed out waiting for %s; jobs: %+v", want, e.q.list())
	return nil
}

func (e *fakeEnv) touch(suffix string) { _ = os.WriteFile(e.calls+"."+suffix, nil, 0o644) }

func (e *fakeEnv) add(t *testing.T, keep bool) {
	t.Helper()
	j := &Job{URL: "https://example.com/v", Output: OutputOptions{Dir: e.folder}}
	j.Download.KeepDownload = keep
	j.Transcode.Preset = "Fast 1080p30"
	if err := e.q.add(j); err != nil {
		t.Fatal(err)
	}
}

// The reason for the setting: HandBrake crashes after a long download, and "Try again" must carry
// on from the conversion rather than downloading for hours again.
func TestFailedConversionResumesFromTheKeptDownload(t *testing.T) {
	e := newFakeEnv(t)
	e.add(t, true)
	failed := e.wait(t, StFailed)

	work := workDirFor(failed)
	if _, err := os.Stat(filepath.Join(work, "fake.mp4")); err != nil {
		t.Fatalf("the download was not kept: %v", err)
	}
	if _, err := os.Stat(filepath.Join(work, "out.mp4")); !os.IsNotExist(err) {
		t.Fatalf("HandBrake's half-written file was left behind: %v", err)
	}
	if len(failed.Downloads) != 1 {
		t.Fatalf("the download is not tracked: %v", failed.Downloads)
	}
	// The record is saved, so it survives the app quitting.
	if b, _ := os.ReadFile(filepath.Join(e.q.dir, "jobs.json")); !strings.Contains(string(b), "fake.mp4") {
		t.Fatalf("jobs.json does not record the kept download: %s", b)
	}

	if err := os.WriteFile(e.calls+".ok", nil, 0o644); err != nil { // HandBrake works now
		t.Fatal(err)
	}
	if !e.q.retry(failed.ID) {
		t.Fatal("retry refused")
	}
	done := e.wait(t, StDone)

	if got := e.count("ytdlp"); got != 1 {
		t.Fatalf("yt-dlp ran %d times; the kept download should have been used", got)
	}
	if got := e.count("hb"); got != 2 {
		t.Fatalf("HandBrake ran %d times, want 2", got)
	}
	if len(done.Outputs) != 1 {
		t.Fatalf("outputs: %v", done.Outputs)
	}
	if b, _ := os.ReadFile(done.Outputs[0]); string(b) != "converted" {
		t.Fatalf("output is %q", b)
	}
	left, _ := os.ReadDir(e.folder)
	if len(left) != 1 || len(done.Downloads) != 0 {
		t.Fatalf("only the finished video should remain; folder has %d entries, downloads %v", len(left), done.Downloads)
	}
}

// 2026-10-09: HandBrake exited normally without writing a video (it did not understand an option),
// and the job failed with a confusing "move ...: no such file or directory".
func TestHandbrakeWritingNothingGivesAClearError(t *testing.T) {
	e := newFakeEnv(t)
	if err := os.WriteFile(e.calls+".nooutput", nil, 0o644); err != nil {
		t.Fatal(err)
	}
	e.add(t, true)
	failed := e.wait(t, StFailed)
	if !strings.Contains(failed.Error, "finished without creating a video") {
		t.Fatalf("error: %q", failed.Error)
	}
	if len(failed.Downloads) != 1 {
		t.Fatalf("the download should still be kept: %v", failed.Downloads)
	}
}

// With the setting off, a failure cleans up and "Try again" starts from the download.
func TestFailedConversionWithoutKeepingStartsOver(t *testing.T) {
	e := newFakeEnv(t)
	e.add(t, false)
	failed := e.wait(t, StFailed)
	if _, err := os.Stat(workDirFor(failed)); !os.IsNotExist(err) {
		t.Fatalf("temporary folder was kept: %v", err)
	}
	if len(failed.Downloads) != 0 {
		t.Fatalf("download tracked although not kept: %v", failed.Downloads)
	}
	_ = os.WriteFile(e.calls+".ok", nil, 0o644)
	e.q.retry(failed.ID)
	e.wait(t, StDone)
	if got := e.count("ytdlp"); got != 2 {
		t.Fatalf("yt-dlp ran %d times, want 2", got)
	}
}

// Removing a failed job deletes the download it kept.
func TestRemovingAJobDeletesItsKeptDownload(t *testing.T) {
	e := newFakeEnv(t)
	e.add(t, true)
	failed := e.wait(t, StFailed)
	if !e.q.remove(failed.ID) {
		t.Fatal("remove refused")
	}
	if _, err := os.Stat(workDirFor(failed)); !os.IsNotExist(err) {
		t.Fatalf("kept download survived removing the job: %v", err)
	}
}

// If the app quits during a conversion, the next launch keeps the download for "Try again".
func TestInterruptedConversionKeepsTheDownload(t *testing.T) {
	data, folder := t.TempDir(), t.TempDir()
	job := &Job{ID: "abc", Status: StTranscoding, Output: OutputOptions{Dir: folder}}
	job.Download.KeepDownload = true
	work := workDirFor(job)
	if err := os.MkdirAll(work, 0o755); err != nil {
		t.Fatal(err)
	}
	kept := filepath.Join(work, "fake.mp4")
	_ = os.WriteFile(kept, []byte("v"), 0o644)
	_ = os.WriteFile(filepath.Join(work, "out.mp4"), []byte("half"), 0o644)
	job.Downloads = []string{kept}
	writeJobs(t, data, job)

	tl, _ := newTools(filepath.Join(data, "bin"))
	q, err := newQueue(data, tl)
	if err != nil {
		t.Fatal(err)
	}
	defer q.shutdown()
	if _, err := os.Stat(kept); err != nil {
		t.Fatalf("the kept download was removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(work, "out.mp4")); !os.IsNotExist(err) {
		t.Fatalf("half-written output was kept: %v", err)
	}
	if js := q.list(); len(js) != 1 || js[0].Status != StFailed || len(js[0].Downloads) != 1 {
		t.Fatalf("job after restart: %+v", js)
	}
}

// A file already on disk is edited by HandBrake alone: no download, and the original is never touched.
func TestEditingAFileOnDiskNeedsNoDownload(t *testing.T) {
	e := newFakeEnv(t)
	e.touch("ok")
	src := filepath.Join(t.TempDir(), "My Lecture.mov")
	if err := os.WriteFile(src, []byte("original"), 0o644); err != nil {
		t.Fatal(err)
	}
	j := &Job{Source: src, Output: OutputOptions{Dir: e.folder, KeepSource: true}}
	j.Download.KeepDownload = true // meaningless for a file: nothing is downloaded
	j.Transcode.Skip = true        // converting is the whole point, so this is ignored
	if err := e.q.add(j); err != nil {
		t.Fatal(err)
	}
	done := e.wait(t, StDone)

	if e.count("ytdlp") != 0 || e.count("hb") != 1 {
		t.Fatalf("yt-dlp ran %d times and HandBrake %d; want 0 and 1", e.count("ytdlp"), e.count("hb"))
	}
	if b, _ := os.ReadFile(src); string(b) != "original" {
		t.Fatalf("the original was changed or removed: %q", b)
	}
	if len(done.Outputs) != 1 || filepath.Base(done.Outputs[0]) != "My Lecture (edited).mp4" {
		t.Fatalf("outputs: %v", done.Outputs)
	}
	if b, _ := os.ReadFile(done.Outputs[0]); string(b) != "converted" {
		t.Fatalf("output is %q", b)
	}
	if done.Title != "My Lecture.mov" || done.URL != "" || len(done.Downloads) != 0 {
		t.Fatalf("job: %+v", done)
	}
	if left, _ := os.ReadDir(e.folder); len(left) != 1 {
		t.Fatalf("only the edited video should be in the folder, found %d entries (keepSource must not copy the original)", len(left))
	}
}

// "Overwrite an existing file" must never overwrite the file being edited.
func TestEditingNeverOverwritesTheOriginal(t *testing.T) {
	e := newFakeEnv(t)
	e.touch("ok")
	src := filepath.Join(e.folder, "clip.mp4")
	if err := os.MkdirAll(e.folder, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(src, []byte("original"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Same folder, same name, same extension, overwrite on: the worst case.
	j := &Job{Source: src, Output: OutputOptions{Dir: e.folder, Filename: "clip", Overwrite: true}}
	if err := e.q.add(j); err != nil {
		t.Fatal(err)
	}
	done := e.wait(t, StDone)
	if b, _ := os.ReadFile(src); string(b) != "original" {
		t.Fatalf("the original was overwritten: %q", b)
	}
	if len(done.Outputs) != 1 || filepath.Base(done.Outputs[0]) != "clip (1).mp4" {
		t.Fatalf("outputs: %v", done.Outputs)
	}
}

func TestEditingRejectsMissingFilesAndFolders(t *testing.T) {
	e := newFakeEnv(t)
	for _, src := range []string{filepath.Join(e.folder, "nope.mp4"), t.TempDir()} {
		if err := e.q.add(&Job{Source: src}); err == nil {
			t.Errorf("%q should be rejected", src)
		}
	}
	if len(e.q.list()) != 0 {
		t.Fatal("nothing should be queued")
	}
}

// If the file goes away before its turn, the job fails clearly instead of running HandBrake on nothing.
func TestEditedFileThatDisappearsFailsClearly(t *testing.T) {
	data := t.TempDir()
	bin := filepath.Join(data, "bin")
	tl, _ := newTools(bin)
	_ = os.WriteFile(filepath.Join(bin, toolHandbrake), []byte("#!/bin/sh\nexit 9\n"), 0o755)
	gone := filepath.Join(t.TempDir(), "gone.mp4")
	writeJobs(t, data, &Job{ID: "abc", Status: StQueued, Source: gone, Title: "gone.mp4", Output: OutputOptions{Dir: t.TempDir()}})
	q, err := newQueue(data, tl)
	if err != nil {
		t.Fatal(err)
	}
	defer q.shutdown()
	e := &fakeEnv{q: q}
	failed := e.wait(t, StFailed)
	if !strings.Contains(failed.Error, "cannot find the file") {
		t.Fatalf("error: %q", failed.Error)
	}
}
