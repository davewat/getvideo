package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// Windows: every tool is downloaded into our own bin folder. Untested on a real machine.

const exeSuffix = ".exe"

func isSystemTool(string) bool     { return false }
func systemToolHint(string) string { return "" }
func prepareExecutable(string)     {}

func ytdlpAsset() string {
	if runtime.GOARCH == "arm64" {
		return "yt-dlp_arm64.exe"
	}
	return "yt-dlp.exe"
}

// interrupt ends the process and its children: Windows has no Ctrl-C signal to send, and
// yt-dlp.exe runs its real work in a child process that a plain kill would leave behind.
func interrupt(p *os.Process) error {
	if err := exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(p.Pid)).Run(); err != nil {
		return p.Kill()
	}
	return nil
}

func defaultDataDir() (string, error) {
	dir, err := os.UserConfigDir() // %AppData%
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "GetVideo"), nil
}

func openBrowser(url string) {
	_ = exec.Command("rundll32", "url.dll,FileProtocolHandler", url).Start()
}

func revealFile(path string) error { return exec.Command("explorer", "/select,"+path).Start() }

// pickFolder shows the Windows folder chooser through PowerShell; "" means the user cancelled.
func pickFolder(ctx context.Context) (string, error) {
	const script = `[Console]::OutputEncoding = [Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
$d = New-Object System.Windows.Forms.FolderBrowserDialog
$d.Description = 'Choose where to save the video'
$top = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
if ($d.ShowDialog($top) -eq 'OK') { [Console]::Out.Write($d.SelectedPath) }`
	out, err := exec.CommandContext(ctx, "powershell", "-NoProfile", "-STA", "-Command", script).Output()
	if err != nil {
		return "", errors.New("The folder chooser could not be opened. Type the folder's path instead.")
	}
	return strings.TrimSpace(string(out)), nil
}

func ffmpegAsset() string {
	if runtime.GOARCH == "arm64" {
		return "ffmpeg-master-latest-winarm64-gpl.zip"
	}
	return "ffmpeg-master-latest-win64-gpl.zip"
}

func extractFfmpeg(_ context.Context, archive, _ string, dst string) error {
	return extractFromZip(archive, "ffmpeg.exe", dst)
}

// installHandbrake takes HandBrakeCLI.exe out of the official Windows zip.
func (t *tools) installHandbrake(ctx context.Context) error {
	r, err := t.release(ctx, "HandBrake/HandBrake")
	if err != nil {
		return err
	}
	suffix := "-win-x86_64.zip"
	if runtime.GOARCH == "arm64" {
		suffix = "-win-aarch64.zip"
	}
	var zipURL string
	for _, a := range r.Assets {
		if strings.HasPrefix(a.Name, "HandBrakeCLI-") && strings.HasSuffix(a.Name, suffix) {
			zipURL = a.URL
		}
	}
	if zipURL == "" {
		return fmt.Errorf("no HandBrakeCLI %s asset in the latest release", suffix)
	}
	work, err := os.MkdirTemp(t.dir, ".hb-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	zp := filepath.Join(work, "hb.zip")
	if err := t.download(ctx, zipURL, zp); err != nil {
		return err
	}
	tmp := filepath.Join(t.dir, ".hb.download")
	defer os.Remove(tmp)
	if err := extractFromZip(zp, "HandBrakeCLI.exe", tmp); err != nil {
		return err
	}
	return t.place(toolHandbrake, tmp, r.Tag)
}
