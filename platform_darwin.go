package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// macOS: every tool is downloaded into our own bin folder.

const exeSuffix = ""

func isSystemTool(string) bool      { return false }
func systemToolHint(string) string  { return "" }
func ytdlpAsset() string            { return "yt-dlp_macos" }
func interrupt(p *os.Process) error { return p.Signal(os.Interrupt) }

func defaultDataDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Application Support", "GetVideo"), nil
}

func openBrowser(url string) { _ = exec.Command("open", url).Start() }

func revealFile(path string) error { return exec.Command("open", "-R", path).Start() }

// pickFolder shows the system folder chooser; "" means the user cancelled.
func pickFolder(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "osascript", "-e",
		`POSIX path of (choose folder with prompt "Choose where to save the video")`).Output()
	if err != nil {
		return "", nil
	}
	return strings.TrimRight(strings.TrimSpace(string(out)), "/"), nil
}

// pickFile shows the system file chooser for a video; "" means the user cancelled.
func pickFile(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "osascript", "-e",
		`POSIX path of (choose file of type {"public.movie"} with prompt "Choose a video to edit")`).Output()
	if err != nil {
		return "", nil
	}
	return strings.TrimSpace(string(out)), nil
}

// prepareExecutable clears the quarantine flag that would block launching a downloaded binary.
func prepareExecutable(path string) {
	_ = exec.Command("xattr", "-d", "com.apple.quarantine", path).Run()
}

// ffmpegURL is Martin Riedl's static macOS build server; it serves arm64 and amd64.
func ffmpegURL() string {
	arch := "arm64"
	if runtime.GOARCH == "amd64" {
		arch = "amd64"
	}
	return "https://ffmpeg.martin-riedl.de/redirect/latest/macos/" + arch + "/release/ffmpeg.zip"
}

// ffmpegLatest reads the version out of the redirect target:
// /download/macos/arm64/<build>_<version>/ffmpeg.zip
func (t *tools) ffmpegLatest(ctx context.Context) (string, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", ffmpegURL(), nil)
	c := *t.http
	c.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err := c.Do(req)
	if err != nil {
		return "", err
	}
	resp.Body.Close()
	parts := strings.Split(resp.Header.Get("Location"), "/")
	if len(parts) < 2 {
		return "", errors.New("unexpected ffmpeg redirect")
	}
	return parts[len(parts)-2], nil
}

func (t *tools) installHandbrake(ctx context.Context) error {
	r, err := t.release(ctx, "HandBrake/HandBrake")
	if err != nil {
		return err
	}
	var dmgURL string
	for _, a := range r.Assets {
		if strings.HasPrefix(a.Name, "HandBrakeCLI-") && strings.HasSuffix(a.Name, ".dmg") {
			dmgURL = a.URL
		}
	}
	if dmgURL == "" {
		return errors.New("no HandBrakeCLI .dmg asset in the latest release")
	}
	work, err := os.MkdirTemp(t.dir, ".hb-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	dmg := filepath.Join(work, "hb.dmg")
	if err := t.download(ctx, dmgURL, dmg); err != nil {
		return err
	}
	mnt := filepath.Join(work, "mnt")
	if err := os.Mkdir(mnt, 0o755); err != nil {
		return err
	}
	if out, err := exec.CommandContext(ctx, "hdiutil", "attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mnt, dmg).CombinedOutput(); err != nil {
		return fmt.Errorf("hdiutil attach: %v: %s", err, out)
	}
	defer exec.Command("hdiutil", "detach", "-force", mnt).Run()
	src := filepath.Join(mnt, "HandBrakeCLI")
	if _, err := os.Stat(src); err != nil {
		return errors.New("HandBrakeCLI not found inside the disk image")
	}
	tmp := filepath.Join(t.dir, ".hb.download")
	defer os.Remove(tmp)
	if err := copyFile(src, tmp); err != nil {
		return err
	}
	return t.place(toolHandbrake, tmp, r.Tag)
}

func (t *tools) installFfmpeg(ctx context.Context) error {
	ver, err := t.ffmpegLatest(ctx)
	if err != nil {
		return err
	}
	work, err := os.MkdirTemp(t.dir, ".ff-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	zp := filepath.Join(work, "ffmpeg.zip")
	if err := t.download(ctx, ffmpegURL(), zp); err != nil {
		return err
	}
	tmp := filepath.Join(t.dir, ".ffmpeg.download")
	defer os.Remove(tmp)
	if err := extractFromZip(zp, "ffmpeg", tmp); err != nil {
		return err
	}
	return t.place(toolFfmpeg, tmp, ver)
}
