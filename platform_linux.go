package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Linux (built for Ubuntu): yt-dlp and ffmpeg are downloaded into our own bin folder, and
// HandBrakeCLI comes from the system, because HandBrake publishes no standalone Linux build.
// Untested on a real machine.

const exeSuffix = ""

func isSystemTool(name string) bool { return name == toolHandbrake }

func systemToolHint(string) string {
	return "GetVideo cannot install HandBrake on Linux. In a terminal, run: sudo apt install handbrake-cli"
}

func prepareExecutable(string)      {}
func interrupt(p *os.Process) error { return p.Signal(os.Interrupt) }

func ytdlpAsset() string {
	if runtime.GOARCH == "arm64" {
		return "yt-dlp_linux_aarch64"
	}
	return "yt-dlp_linux"
}

func defaultDataDir() (string, error) {
	if dir := os.Getenv("XDG_DATA_HOME"); dir != "" {
		return filepath.Join(dir, "getvideo"), nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".local", "share", "getvideo"), nil
}

func openBrowser(url string) { _ = exec.Command("xdg-open", url).Start() }

// revealFile opens the file's folder; there is no portable way to select the file in it.
func revealFile(path string) error { return exec.Command("xdg-open", filepath.Dir(path)).Start() }

// pickFolder uses zenity or kdialog when one is installed; "" means the user cancelled.
func pickFolder(ctx context.Context) (string, error) {
	const title = "Choose where to save the video"
	var cmd *exec.Cmd
	if p, err := exec.LookPath("zenity"); err == nil {
		cmd = exec.CommandContext(ctx, p, "--file-selection", "--directory", "--title="+title)
	} else if p, err := exec.LookPath("kdialog"); err == nil {
		cmd = exec.CommandContext(ctx, p, "--title", title, "--getexistingdirectory", ".")
	} else {
		return "", errors.New("No folder chooser is installed. Type the folder's path instead.")
	}
	out, err := cmd.Output()
	if err != nil {
		return "", nil
	}
	return strings.TrimSpace(string(out)), nil
}

func ffmpegAsset() string {
	if runtime.GOARCH == "arm64" {
		return "ffmpeg-master-latest-linuxarm64-gpl.tar.xz"
	}
	return "ffmpeg-master-latest-linux64-gpl.tar.xz"
}

// extractFfmpeg unpacks the .tar.xz with the system's tar (Go has no xz reader) and takes ffmpeg out.
func extractFfmpeg(ctx context.Context, archive, work, dst string) error {
	if out, err := exec.CommandContext(ctx, "tar", "-xJf", archive, "-C", work).CombinedOutput(); err != nil {
		return fmt.Errorf("tar: %v: %s", err, out)
	}
	var found string
	_ = filepath.WalkDir(work, func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() && d.Name() == "ffmpeg" {
			found = p
			return fs.SkipAll
		}
		return nil
	})
	if found == "" {
		return errors.New("ffmpeg not found in the archive")
	}
	return os.Rename(found, dst)
}

// installHandbrake is never reached: HandBrakeCLI is a system tool here (see tools.install).
func (t *tools) installHandbrake(context.Context) error {
	return errors.New(systemToolHint(toolHandbrake))
}
