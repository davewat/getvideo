package main

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// DownloadOptions are the curated yt-dlp controls; ExtraArgs is the escape hatch.
type DownloadOptions struct {
	MaxHeight      int      `json:"maxHeight"`      // 0 = best available
	AudioOnly      bool     `json:"audioOnly"`      // -x
	AudioFormat    string   `json:"audioFormat"`    // mp3, m4a, opus, flac, wav (with AudioOnly)
	MergeContainer string   `json:"mergeContainer"` // mp4, mkv, webm ("" = yt-dlp default)
	FormatSort     string   `json:"formatSort"`     // -S, e.g. "res,codec:h264"
	CustomFormat   string   `json:"customFormat"`   // -f, overrides the quality choice
	NoPlaylist     bool     `json:"noPlaylist"`
	Subtitles      bool     `json:"subtitles"`
	AutoSubs       bool     `json:"autoSubs"`
	SubLangs       string   `json:"subLangs"` // e.g. "en,es" or "all"
	EmbedSubs      bool     `json:"embedSubs"`
	EmbedMetadata  bool     `json:"embedMetadata"`
	EmbedThumbnail bool     `json:"embedThumbnail"`
	CookiesBrowser string   `json:"cookiesBrowser"` // safari, chrome, firefox, ...
	RateLimit      string   `json:"rateLimit"`      // e.g. 2M
	Proxy          string   `json:"proxy"`
	SponsorBlock   []string `json:"sponsorBlock"` // categories to remove
	ExtraArgs      string   `json:"extraArgs"`
}

// TranscodeOptions are the curated HandBrakeCLI controls.
type TranscodeOptions struct {
	Skip          bool    `json:"skip"` // keep the downloaded file as-is
	Preset        string  `json:"preset"`
	Container     string  `json:"container"`   // mp4, mkv, webm
	Encoder       string  `json:"encoder"`     // "" = preset default
	QualityMode   string  `json:"qualityMode"` // "rf" or "bitrate" ("" = preset default)
	Quality       float64 `json:"quality"`
	VideoBitrate  int     `json:"videoBitrate"`  // kbps
	EncoderPreset string  `json:"encoderPreset"` // e.g. fast, medium, slow
	Framerate     string  `json:"framerate"`     // "" = same as source
	FramerateMode string  `json:"framerateMode"` // vfr, cfr, pfr
	MaxWidth      int     `json:"maxWidth"`
	MaxHeight     int     `json:"maxHeight"`
	Deinterlace   string  `json:"deinterlace"`  // "", decomb, yadif
	AudioEncoder  string  `json:"audioEncoder"` // "" = preset, aac, ac3, copy, opus, ...
	AudioBitrate  int     `json:"audioBitrate"`
	AllAudio      bool    `json:"allAudio"`
	AllSubs       bool    `json:"allSubs"`
	WebOptimize   bool    `json:"webOptimize"`
	ExtraArgs     string  `json:"extraArgs"`
}

// OutputOptions say where the finished file goes.
type OutputOptions struct {
	Dir        string `json:"dir"`
	Filename   string `json:"filename"`   // without extension; "" = source title
	KeepSource bool   `json:"keepSource"` // also keep the untranscoded download
	Overwrite  bool   `json:"overwrite"`
}

var heightRe = func(h int) string { return strconv.Itoa(h) }

func (o DownloadOptions) args() ([]string, error) {
	var a []string
	switch {
	case o.CustomFormat != "":
		a = append(a, "-f", o.CustomFormat)
	case o.AudioOnly:
		a = append(a, "-f", "ba/b")
	case o.MaxHeight > 0:
		h := heightRe(o.MaxHeight)
		a = append(a, "-f", "bv*[height<="+h+"]+ba/b[height<="+h+"]")
	default:
		a = append(a, "-f", "bv*+ba/b")
	}
	if o.FormatSort != "" {
		a = append(a, "-S", o.FormatSort)
	}
	if o.AudioOnly {
		af := o.AudioFormat
		if af == "" {
			af = "best"
		}
		a = append(a, "-x", "--audio-format", af)
	} else if o.MergeContainer != "" {
		a = append(a, "--merge-output-format", o.MergeContainer)
	}
	if o.NoPlaylist {
		a = append(a, "--no-playlist")
	}
	if o.Subtitles {
		a = append(a, "--write-subs")
	}
	if o.AutoSubs {
		a = append(a, "--write-auto-subs")
	}
	if o.Subtitles || o.AutoSubs {
		if o.SubLangs != "" {
			a = append(a, "--sub-langs", o.SubLangs)
		}
		if o.EmbedSubs {
			a = append(a, "--embed-subs")
		}
	}
	if o.EmbedMetadata {
		a = append(a, "--embed-metadata")
	}
	if o.EmbedThumbnail {
		a = append(a, "--embed-thumbnail")
	}
	if o.CookiesBrowser != "" {
		a = append(a, "--cookies-from-browser", o.CookiesBrowser)
	}
	if o.RateLimit != "" {
		a = append(a, "-r", o.RateLimit)
	}
	if o.Proxy != "" {
		a = append(a, "--proxy", o.Proxy)
	}
	if len(o.SponsorBlock) > 0 {
		a = append(a, "--sponsorblock-remove", strings.Join(o.SponsorBlock, ","))
	}
	extra, err := splitArgs(o.ExtraArgs)
	if err != nil {
		return nil, fmt.Errorf("yt-dlp extra args: %w", err)
	}
	return append(a, extra...), nil
}

// args builds HandBrakeCLI arguments after -i/-o.
func (o TranscodeOptions) args() ([]string, error) {
	var a []string
	if o.Preset != "" {
		a = append(a, "--preset", o.Preset)
	}
	switch o.Container {
	case "mp4":
		a = append(a, "-f", "av_mp4")
	case "mkv":
		a = append(a, "-f", "av_mkv")
	case "webm":
		a = append(a, "-f", "av_webm")
	}
	if o.Encoder != "" {
		a = append(a, "-e", o.Encoder)
	}
	if o.EncoderPreset != "" {
		a = append(a, "--encoder-preset", o.EncoderPreset)
	}
	switch o.QualityMode {
	case "rf":
		a = append(a, "-q", strconv.FormatFloat(o.Quality, 'f', -1, 64))
	case "bitrate":
		if o.VideoBitrate <= 0 {
			return nil, errors.New("video bitrate must be > 0")
		}
		a = append(a, "-b", strconv.Itoa(o.VideoBitrate))
	}
	if o.Framerate != "" {
		a = append(a, "-r", o.Framerate)
	}
	switch o.FramerateMode {
	case "vfr", "cfr", "pfr":
		a = append(a, "--"+o.FramerateMode)
	}
	if o.MaxWidth > 0 {
		a = append(a, "--maxWidth", strconv.Itoa(o.MaxWidth))
	}
	if o.MaxHeight > 0 {
		a = append(a, "--maxHeight", strconv.Itoa(o.MaxHeight))
	}
	switch o.Deinterlace {
	case "decomb", "yadif":
		a = append(a, "--"+o.Deinterlace)
	}
	if o.AudioEncoder != "" {
		a = append(a, "-E", o.AudioEncoder)
	}
	if o.AudioBitrate > 0 {
		a = append(a, "-B", strconv.Itoa(o.AudioBitrate))
	}
	if o.AllAudio {
		a = append(a, "--all-audio")
	}
	if o.AllSubs {
		a = append(a, "--all-subtitles")
	}
	if o.WebOptimize {
		a = append(a, "--optimize")
	}
	extra, err := splitArgs(o.ExtraArgs)
	if err != nil {
		return nil, fmt.Errorf("HandBrake extra args: %w", err)
	}
	return append(a, extra...), nil
}

// splitArgs is a small shell-style splitter: whitespace separated, with '...' and "..." quoting.
func splitArgs(s string) ([]string, error) {
	var out []string
	var cur strings.Builder
	var quote rune
	started := false
	for _, r := range s {
		switch {
		case quote != 0:
			if r == quote {
				quote = 0
			} else {
				cur.WriteRune(r)
			}
		case r == '\'' || r == '"':
			quote, started = r, true
		case r == ' ' || r == '\t' || r == '\n':
			if started || cur.Len() > 0 {
				out = append(out, cur.String())
				cur.Reset()
				started = false
			}
		default:
			cur.WriteRune(r)
		}
	}
	if quote != 0 {
		return nil, errors.New("unterminated quote")
	}
	if started || cur.Len() > 0 {
		out = append(out, cur.String())
	}
	return out, nil
}
