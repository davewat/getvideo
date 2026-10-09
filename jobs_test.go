package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The working folder is where the video is saved AND where yt-dlp and HandBrake keep their
// temporary files (2026-10-09: before, temporary files lived in the app's own data folder).
func TestWorkDirIsInsideTheWorkingFolder(t *testing.T) {
	j := &Job{ID: "abc", Output: OutputOptions{Dir: "/Volumes/Big/Videos"}}
	if got, want := workDirFor(j), "/Volumes/Big/Videos/.getvideo-abc"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

// A job interrupted by a restart must not leave its temporary folder behind in the user's folder.
func TestInterruptedJobsTemporaryFolderIsRemoved(t *testing.T) {
	data, folder := t.TempDir(), t.TempDir()
	job := &Job{ID: "abc", Status: StDownloading, Output: OutputOptions{Dir: folder}}
	leftover := workDirFor(job)
	if err := os.MkdirAll(leftover, 0o755); err != nil {
		t.Fatal(err)
	}
	keep := filepath.Join(folder, "My Video.mp4") // the user's own files are never touched
	if err := os.WriteFile(keep, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal([]*Job{job})
	if err := os.WriteFile(filepath.Join(data, "jobs.json"), b, 0o644); err != nil {
		t.Fatal(err)
	}
	tl, err := newTools(filepath.Join(data, "bin"))
	if err != nil {
		t.Fatal(err)
	}
	q, err := newQueue(data, tl)
	if err != nil {
		t.Fatal(err)
	}
	defer q.shutdown()

	if _, err := os.Stat(leftover); !os.IsNotExist(err) {
		t.Fatalf("temporary folder still exists: %v", err)
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("a user file was removed: %v", err)
	}
}
