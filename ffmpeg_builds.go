//go:build windows || linux

package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
)

// Windows and Linux take ffmpeg from the yt-dlp project's FFmpeg-Builds, which publishes one
// rolling "latest" release rebuilt every day. To avoid a 150 MB download on every start, the
// version we track is the month the build was made: ffmpeg updates at most once a month.

const ffmpegBuildsRepo = "yt-dlp/FFmpeg-Builds"

// ffmpegBuild finds this platform's asset and its year-month version, e.g. "2026-10".
func (t *tools) ffmpegBuild(ctx context.Context) (url, version string, err error) {
	r, err := t.release(ctx, ffmpegBuildsRepo)
	if err != nil {
		return "", "", err
	}
	for _, a := range r.Assets {
		if a.Name == ffmpegAsset() && len(a.Updated) >= 7 {
			return a.URL, a.Updated[:7], nil
		}
	}
	return "", "", errors.New("no " + ffmpegAsset() + " asset in the latest FFmpeg-Builds release")
}

func (t *tools) ffmpegLatest(ctx context.Context) (string, error) {
	_, v, err := t.ffmpegBuild(ctx)
	return v, err
}

func (t *tools) installFfmpeg(ctx context.Context) error {
	url, ver, err := t.ffmpegBuild(ctx)
	if err != nil {
		return err
	}
	work, err := os.MkdirTemp(t.dir, ".ff-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(work)
	archive := filepath.Join(work, ffmpegAsset())
	if err := t.download(ctx, url, archive); err != nil {
		return err
	}
	tmp := filepath.Join(t.dir, ".ffmpeg.download")
	defer os.Remove(tmp)
	if err := extractFfmpeg(ctx, archive, work, tmp); err != nil {
		return err
	}
	return t.place(toolFfmpeg, tmp, ver)
}
