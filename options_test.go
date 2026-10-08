package main

import (
	"reflect"
	"testing"
)

func TestSplitArgs(t *testing.T) {
	got, err := splitArgs(`--a "b c" 'd e' f=""`)
	want := []string{"--a", "b c", "d e", "f="}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := splitArgs(`"open`); err == nil {
		t.Fatal("expected unterminated quote error")
	}
}

func TestDownloadArgs(t *testing.T) {
	a, err := DownloadOptions{MaxHeight: 720, MergeContainer: "mp4", NoPlaylist: true, ExtraArgs: "--retries 3"}.args()
	want := []string{"-f", "bv*[height<=720]+ba/b[height<=720]", "--merge-output-format", "mp4", "--no-playlist", "--retries", "3"}
	if err != nil || !reflect.DeepEqual(a, want) {
		t.Fatalf("got %q, %v", a, err)
	}
	a, _ = DownloadOptions{AudioOnly: true, AudioFormat: "mp3"}.args()
	if !reflect.DeepEqual(a, []string{"-f", "ba/b", "-x", "--audio-format", "mp3"}) {
		t.Fatalf("audio args: %q", a)
	}
}

func TestTranscodeArgs(t *testing.T) {
	a, err := TranscodeOptions{Preset: "Fast 1080p30", Container: "mkv", QualityMode: "rf", Quality: 20, MaxWidth: 1280, WebOptimize: true}.args()
	want := []string{"--preset", "Fast 1080p30", "-f", "av_mkv", "-q", "20", "--maxWidth", "1280", "--optimize"}
	if err != nil || !reflect.DeepEqual(a, want) {
		t.Fatalf("got %q, %v", a, err)
	}
	if _, err := (TranscodeOptions{QualityMode: "bitrate"}).args(); err == nil {
		t.Fatal("bitrate mode without a bitrate must fail")
	}
}

func TestParsePresetList(t *testing.T) {
	g := parsePresetList("General/\n    Fast 1080p30\n        H.264 desc\n    Fast 720p30\nWeb/\n    Discord Small\n")
	if len(g) != 2 || g[0].Category != "General" || len(g[0].Presets) != 2 || g[1].Presets[0] != "Discord Small" {
		t.Fatalf("got %+v", g)
	}
}

func TestSanitize(t *testing.T) {
	if got := sanitize("../a/b: c"); got != "..-a-b- c" && got != "-a-b- c" {
		t.Fatalf("got %q", got)
	}
	// Characters Windows refuses in a file name are replaced on every platform.
	if got := sanitize(`What? "A" <b>|c*`); got != "What- -A- -b--c-" {
		t.Fatalf("got %q", got)
	}
	if sanitize("") != "video" {
		t.Fatal("empty name must fall back")
	}
}
