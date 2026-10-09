package main

import (
	"reflect"
	"testing"
)

func TestParseClock(t *testing.T) {
	ok := map[string]float64{
		"3:00:00": 10800, "90:00": 5400, "0:45": 45, "1:02:03": 3723,
		"3h": 10800, "90m": 5400, "45s": 45, "1h30m": 5400, "1.5h": 5400, " 2 h 15 m ": 8100,
	}
	for in, want := range ok {
		if got, err := parseClock(in); err != nil || got != want {
			t.Errorf("parseClock(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, in := range []string{"", "3", "abc", "1:2:3:4", "-5:00", "0", "0h", "3 hours"} {
		if _, err := parseClock(in); err == nil {
			t.Errorf("parseClock(%q) should fail", in)
		}
	}
}

func TestScanDuration(t *testing.T) {
	out := "[18:19:07] scan: decoding previews for title 1\n+ title 1:\n  + duration: 12:34:56\n    + 1: duration 00:00:05\n"
	if d, ok := scanDuration(out); !ok || d != 12*3600+34*60+56 {
		t.Fatalf("got %v %v", d, ok)
	}
	if _, ok := scanDuration("nothing here"); ok {
		t.Fatal("should not find a duration")
	}
}

// The twelve-hour example: shorten to three hours, or to 25 percent.
func TestTrimWindow(t *testing.T) {
	const total = 12 * 3600
	cases := []struct {
		name        string
		o           TranscodeOptions
		start, size float64
		ok          bool
	}{
		{"first 3h", TranscodeOptions{TrimMode: "duration", TrimLength: "3:00:00"}, 0, 10800, true},
		{"last 3h", TranscodeOptions{TrimMode: "duration", TrimLength: "3h", TrimKeep: "last"}, 9 * 3600, 10800, true},
		{"middle 4h", TranscodeOptions{TrimMode: "duration", TrimLength: "4h", TrimKeep: "middle"}, 4 * 3600, 4 * 3600, true},
		{"25 percent", TranscodeOptions{TrimMode: "percent", TrimPercent: 25}, 0, 3 * 3600, true},
		{"last 50 percent", TranscodeOptions{TrimMode: "percent", TrimPercent: 50, TrimKeep: "last"}, 6 * 3600, 6 * 3600, true},
		{"longer than the video", TranscodeOptions{TrimMode: "duration", TrimLength: "13h"}, 0, 0, false},
		{"100 percent", TranscodeOptions{TrimMode: "percent", TrimPercent: 100}, 0, 0, false},
		{"off", TranscodeOptions{}, 0, 0, false},
	}
	for _, c := range cases {
		start, size, ok := c.o.trimWindow(total)
		if ok != c.ok || (ok && (start != c.start || size != c.size)) {
			t.Errorf("%s: got %v, %v, %v; want %v, %v, %v", c.name, start, size, ok, c.start, c.size, c.ok)
		}
	}
}

func TestTrimArgs(t *testing.T) {
	if got := trimArgs(0, 10800); !reflect.DeepEqual(got, []string{"--stop-at", "duration:10800"}) {
		t.Fatalf("got %q", got)
	}
	if got := trimArgs(32400, 10800); !reflect.DeepEqual(got, []string{"--start-at", "duration:32400", "--stop-at", "duration:10800"}) {
		t.Fatalf("got %q", got)
	}
}

func TestNeedsScan(t *testing.T) {
	// Keeping the first part of a fixed length needs only --stop-at; everything else needs the length.
	if (TranscodeOptions{TrimMode: "duration", TrimKeep: "first"}).needsScan() {
		t.Error("first part of a fixed length needs no scan")
	}
	if !(TranscodeOptions{TrimMode: "duration", TrimKeep: "last"}).needsScan() || !(TranscodeOptions{TrimMode: "percent"}).needsScan() {
		t.Error("last part, and percentages, need the video's length")
	}
}

func TestValidateTrim(t *testing.T) {
	for _, o := range []TranscodeOptions{
		{TrimMode: "duration", TrimLength: "soon"},
		{TrimMode: "percent", TrimPercent: 0},
		{TrimMode: "percent", TrimPercent: 101},
		{TrimMode: "weekly"},
		{TrimMode: "duration", TrimLength: "1h", TrimKeep: "some"},
	} {
		if _, err := o.args(); err == nil {
			t.Errorf("%+v should be rejected", o)
		}
	}
	if _, err := (TranscodeOptions{TrimMode: "percent", TrimPercent: 50, TrimKeep: "middle"}).args(); err != nil {
		t.Errorf("valid settings rejected: %v", err)
	}
}
