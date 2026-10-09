package main

import (
	"errors"
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// Shortening a video: HandBrake can start and stop encoding at a point in time, so "shorten to
// three hours" or "keep 25%" is a start offset and a length passed to --start-at and --stop-at.

var clockUnits = regexp.MustCompile(`^(?:(\d+(?:\.\d+)?)h)?(?:(\d+(?:\.\d+)?)m)?(?:(\d+(?:\.\d+)?)s)?$`)

// parseClock reads a length of time as people write it: "3:00:00" (hours), "90:00" (minutes and
// seconds), or with units: "3h", "90m", "45s", "1h30m". A bare number is refused, because
// "3" could as easily mean hours as minutes.
func parseClock(s string) (float64, error) {
	s = strings.ToLower(strings.ReplaceAll(strings.TrimSpace(s), " ", ""))
	bad := errors.New(`enter a length like 3:00:00, 90:00 or 3h`)
	if s == "" {
		return 0, bad
	}
	if strings.Contains(s, ":") {
		parts := strings.Split(s, ":")
		if len(parts) > 3 {
			return 0, bad
		}
		total := 0.0
		for _, p := range parts {
			n, err := strconv.ParseFloat(p, 64)
			if err != nil || n < 0 {
				return 0, bad
			}
			total = total*60 + n
		}
		return total, nil
	}
	m := clockUnits.FindStringSubmatch(s)
	if m == nil {
		return 0, bad
	}
	total := 0.0
	for i, unit := range []float64{3600, 60, 1} {
		if m[i+1] != "" {
			n, _ := strconv.ParseFloat(m[i+1], 64)
			total += n * unit
		}
	}
	if total == 0 {
		return 0, bad
	}
	return total, nil
}

// clockString writes seconds as H:MM:SS.
func clockString(seconds float64) string {
	s := int(math.Round(seconds))
	return fmt.Sprintf("%d:%02d:%02d", s/3600, s/60%60, s%60)
}

var scanDurationRe = regexp.MustCompile(`(?m)^\s*\+ duration: (\d+):(\d\d):(\d\d)`)

// scanDuration finds the length of the first title in HandBrakeCLI --scan output.
func scanDuration(out string) (float64, bool) {
	m := scanDurationRe.FindStringSubmatch(out)
	if m == nil {
		return 0, false
	}
	h, _ := strconv.Atoi(m[1])
	mi, _ := strconv.Atoi(m[2])
	s, _ := strconv.Atoi(m[3])
	return float64(h*3600 + mi*60 + s), true
}

// validateTrim rejects shortening settings that could not be applied.
func (o TranscodeOptions) validateTrim() error {
	switch o.TrimMode {
	case "":
		return nil
	case "duration":
		if _, err := parseClock(o.TrimLength); err != nil {
			return fmt.Errorf("shorten: %w", err)
		}
	case "percent":
		if o.TrimPercent <= 0 || o.TrimPercent > 100 {
			return errors.New("shorten: the percentage to keep must be between 1 and 100")
		}
	default:
		return fmt.Errorf("shorten: unknown mode %q", o.TrimMode)
	}
	switch o.TrimKeep {
	case "", "first", "last", "middle":
		return nil
	}
	return fmt.Errorf("shorten: unknown part to keep %q", o.TrimKeep)
}

// needsScan is true when the video's length must be read before the cut can be worked out. Keeping
// the first part of a fixed length does not need it: HandBrake just stops after that long.
func (o TranscodeOptions) needsScan() bool {
	return o.TrimMode == "percent" || (o.TrimMode == "duration" && o.TrimKeep != "" && o.TrimKeep != "first")
}

// trimWindow works out which part to keep: where it starts and how long it is, in seconds.
// total is the video's length (ignored when needsScan is false). ok is false when nothing is cut,
// either because shortening is off or because the video is already no longer than asked for.
func (o TranscodeOptions) trimWindow(total float64) (start, length float64, ok bool) {
	var want float64
	switch o.TrimMode {
	case "duration":
		want, _ = parseClock(o.TrimLength)
	case "percent":
		want = total * o.TrimPercent / 100
	default:
		return 0, 0, false
	}
	if want <= 0 || (total > 0 && want >= total) {
		return 0, 0, false
	}
	switch o.TrimKeep {
	case "last":
		start = total - want
	case "middle":
		start = (total - want) / 2
	}
	return math.Floor(start), math.Round(want), true
}

// trimArgs are HandBrakeCLI's arguments for keeping a stretch of the video. --stop-at counts from
// the start point, so it is the length kept.
func trimArgs(start, length float64) []string {
	args := []string{"--stop-at", fmt.Sprintf("duration:%d", int(length))}
	if start > 0 {
		args = append([]string{"--start-at", fmt.Sprintf("duration:%d", int(start))}, args...)
	}
	return args
}
