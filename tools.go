package main

import (
	"archive/zip"
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Tool names.
const (
	toolYtdlp     = "yt-dlp"
	toolHandbrake = "HandBrakeCLI"
	toolFfmpeg    = "ffmpeg"
)

var toolNames = []string{toolYtdlp, toolHandbrake, toolFfmpeg}

// ToolStatus is what the UI shows for one managed tool.
type ToolStatus struct {
	Name      string `json:"name"`
	Installed bool   `json:"installed"`
	Version   string `json:"version,omitempty"`
	Latest    string `json:"latest,omitempty"`
	Update    bool   `json:"updateAvailable"`
	Busy      bool   `json:"busy"`
	Error     string `json:"error,omitempty"`
}

type tools struct {
	dir  string
	http *http.Client

	mu   sync.Mutex
	busy map[string]bool
	errs map[string]string
}

func newTools(dir string) (*tools, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	return &tools{
		dir:  dir,
		http: &http.Client{Timeout: 30 * time.Minute},
		busy: map[string]bool{},
		errs: map[string]string{},
	}, nil
}

// path is where a tool's executable lives: in our own bin folder, or wherever the system has it
// for a tool this platform does not manage (see isSystemTool).
func (t *tools) path(name string) string {
	if isSystemTool(name) {
		p, _ := exec.LookPath(name)
		return p
	}
	return filepath.Join(t.dir, name+exeSuffix)
}

func (t *tools) installed(name string) bool {
	p := t.path(name)
	if p == "" {
		return false
	}
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func (t *tools) versionFile(name string) string { return filepath.Join(t.dir, name+".version") }

var handbrakeVersionRe = regexp.MustCompile(`HandBrake (\d[^\s]*)`)

// version is the version recorded at install time; a system tool is asked directly.
func (t *tools) version(name string) string {
	if !t.installed(name) {
		return ""
	}
	if isSystemTool(name) {
		out, _ := exec.Command(t.path(name), "--version").CombinedOutput()
		if m := handbrakeVersionRe.FindSubmatch(out); m != nil {
			return string(m[1])
		}
		return "installed"
	}
	if b, err := os.ReadFile(t.versionFile(name)); err == nil {
		return strings.TrimSpace(string(b))
	}
	return ""
}

// status reports every tool. checkLatest hits the network for the newest versions.
func (t *tools) status(ctx context.Context, checkLatest bool) []ToolStatus {
	out := make([]ToolStatus, 0, len(toolNames))
	for _, n := range toolNames {
		s := ToolStatus{Name: n, Installed: t.installed(n), Version: t.version(n)}
		t.mu.Lock()
		s.Busy, s.Error = t.busy[n], t.errs[n]
		t.mu.Unlock()
		if isSystemTool(n) && !s.Installed && s.Error == "" {
			s.Error = systemToolHint(n)
		}
		if checkLatest && !isSystemTool(n) {
			if v, err := t.latest(ctx, n); err == nil {
				s.Latest = v
				s.Update = s.Installed && v != s.Version
			}
		}
		out = append(out, s)
	}
	return out
}

type ghRelease struct {
	Tag    string `json:"tag_name"`
	Assets []struct {
		Name    string `json:"name"`
		URL     string `json:"browser_download_url"`
		Updated string `json:"updated_at"`
	} `json:"assets"`
}

func (t *tools) getJSON(ctx context.Context, url string, v any) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "getvideo")
	resp, err := t.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("GET %s: %s", url, resp.Status)
	}
	return json.NewDecoder(resp.Body).Decode(v)
}

func (t *tools) release(ctx context.Context, repo string) (*ghRelease, error) {
	var r ghRelease
	if err := t.getJSON(ctx, "https://api.github.com/repos/"+repo+"/releases/latest", &r); err != nil {
		return nil, err
	}
	return &r, nil
}

func (t *tools) latest(ctx context.Context, name string) (string, error) {
	switch name {
	case toolYtdlp:
		r, err := t.release(ctx, "yt-dlp/yt-dlp")
		if err != nil {
			return "", err
		}
		return r.Tag, nil
	case toolHandbrake:
		r, err := t.release(ctx, "HandBrake/HandBrake")
		if err != nil {
			return "", err
		}
		return r.Tag, nil
	case toolFfmpeg:
		return t.ffmpegLatest(ctx)
	}
	return "", errors.New("unknown tool")
}

// install downloads (or updates) a tool. Safe to call for an already-installed tool.
func (t *tools) install(ctx context.Context, name string) error {
	t.mu.Lock()
	if t.busy[name] {
		t.mu.Unlock()
		return errors.New("already in progress")
	}
	t.busy[name], t.errs[name] = true, ""
	t.mu.Unlock()
	defer func() { t.mu.Lock(); t.busy[name] = false; t.mu.Unlock() }()

	var err error
	if isSystemTool(name) {
		// Not ours to install: say how, and report success once the user has done it.
		if !t.installed(name) {
			err = errors.New(systemToolHint(name))
			t.mu.Lock()
			t.errs[name] = err.Error()
			t.mu.Unlock()
		}
		return err
	}
	switch name {
	case toolYtdlp:
		err = t.installYtdlp(ctx)
	case toolHandbrake:
		err = t.installHandbrake(ctx)
	case toolFfmpeg:
		err = t.installFfmpeg(ctx)
	default:
		err = errors.New("unknown tool")
	}
	if err != nil {
		t.mu.Lock()
		t.errs[name] = err.Error()
		t.mu.Unlock()
	}
	return err
}

func (t *tools) download(ctx context.Context, url, dst string) error {
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	req.Header.Set("User-Agent", "getvideo")
	resp, err := t.http.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("download %s: %s", url, resp.Status)
	}
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func sha256File(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// place atomically moves a finished binary into the tools dir and records its version.
func (t *tools) place(name, src, version string) error {
	if err := os.Chmod(src, 0o755); err != nil {
		return err
	}
	prepareExecutable(src)
	dst := t.path(name)
	_ = os.Remove(dst) // Windows cannot rename over an existing file
	if err := os.Rename(src, dst); err != nil {
		return err
	}
	return os.WriteFile(t.versionFile(name), []byte(version+"\n"), 0o644)
}

func (t *tools) installYtdlp(ctx context.Context) error {
	r, err := t.release(ctx, "yt-dlp/yt-dlp")
	if err != nil {
		return err
	}
	var binURL, sumsURL string
	for _, a := range r.Assets {
		switch a.Name {
		case ytdlpAsset():
			binURL = a.URL
		case "SHA2-256SUMS":
			sumsURL = a.URL
		}
	}
	if binURL == "" {
		return fmt.Errorf("no %s asset in the latest release", ytdlpAsset())
	}
	tmp := filepath.Join(t.dir, ".yt-dlp.download")
	defer os.Remove(tmp)
	if err := t.download(ctx, binURL, tmp); err != nil {
		return err
	}
	if sumsURL != "" {
		sums := filepath.Join(t.dir, ".yt-dlp.sums")
		defer os.Remove(sums)
		if err := t.download(ctx, sumsURL, sums); err != nil {
			return err
		}
		want := checksumFor(sums, ytdlpAsset())
		got, err := sha256File(tmp)
		if err != nil {
			return err
		}
		if want == "" || want != got {
			return fmt.Errorf("yt-dlp checksum mismatch (want %q, got %s)", want, got)
		}
	}
	return t.place(toolYtdlp, tmp, r.Tag)
}

func checksumFor(sumsFile, asset string) string {
	f, err := os.Open(sumsFile)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Fields(sc.Text())
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == asset {
			return fields[0]
		}
	}
	return ""
}

// extractFromZip copies the first file named base out of a zip archive, wherever it sits inside.
func extractFromZip(zipPath, base, dst string) error {
	zr, err := zip.OpenReader(zipPath)
	if err != nil {
		return err
	}
	defer zr.Close()
	for _, f := range zr.File {
		if filepath.Base(f.Name) != base || f.FileInfo().IsDir() {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			return err
		}
		out, err := os.Create(dst)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(out, rc)
		rc.Close()
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		return err
	}
	return fmt.Errorf("%s not found in the archive", base)
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// presets lists HandBrake preset names grouped by category.
type PresetGroup struct {
	Category string   `json:"category"`
	Presets  []string `json:"presets"`
}

var presetCache struct {
	sync.Mutex
	ver    string
	groups []PresetGroup
}

func (t *tools) presets(ctx context.Context) ([]PresetGroup, error) {
	if !t.installed(toolHandbrake) {
		return nil, errors.New("HandBrakeCLI is not installed")
	}
	presetCache.Lock()
	defer presetCache.Unlock()
	if v := t.version(toolHandbrake); presetCache.groups != nil && presetCache.ver == v {
		return presetCache.groups, nil
	}
	out, err := exec.CommandContext(ctx, t.path(toolHandbrake), "--preset-list").CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("--preset-list: %v", err)
	}
	groups := parsePresetList(string(out))
	presetCache.ver, presetCache.groups = t.version(toolHandbrake), groups
	return groups, nil
}

var versionRe = regexp.MustCompile(`^\S`)

// parsePresetList understands the "Category/" header, indented preset, indented description layout.
func parsePresetList(s string) []PresetGroup {
	var groups []PresetGroup
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimRight(line, "\r")
		switch {
		case strings.HasPrefix(line, "    ") && !strings.HasPrefix(line, "        "):
			if len(groups) > 0 {
				name := strings.TrimSpace(line)
				if name != "" {
					g := &groups[len(groups)-1]
					g.Presets = append(g.Presets, name)
				}
			}
		case strings.HasPrefix(line, "    "):
			// preset description line
		case strings.HasSuffix(line, "/") && versionRe.MatchString(line):
			groups = append(groups, PresetGroup{Category: strings.TrimSuffix(line, "/")})
		}
	}
	return groups
}
