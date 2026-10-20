package main

import (
	"context"
	"errors"
	"fmt"
	"testing"
)

// A failed lookup of the newest version is reported in words a person can act on (2026-10-19: it
// used to be dropped silently, so "Check for updates" appeared to do nothing).
func TestCheckMessage(t *testing.T) {
	cases := map[string]error{
		"The server did not answer in time.":                                 context.DeadlineExceeded,
		"GitHub is limiting requests right now. Try again in a few minutes.": fmt.Errorf("GET https://api.github.com/x: 403 rate limit exceeded"),
		"something unexpected":                                               errors.New("something unexpected"),
	}
	for want, err := range cases {
		if got := checkMessage(err); got != want {
			t.Errorf("checkMessage(%v) = %q, want %q", err, got, want)
		}
	}
}
