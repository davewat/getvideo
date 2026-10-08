# GetVideo

**Website: https://davewat.github.io/getvideo/**

Paste a link. Get a file.

GetVideo is a free Mac app for teachers. It saves an educational video to your computer, so you
can show it in class without the internet and without the adverts.

For educational use only. Save only videos you have the right to keep and show, and follow the
terms of the site they come from.

## Why I made this

I made GetVideo for the teachers in my life. They find short, educational videos online that are
exactly right for a lesson. Then the classroom has no internet that day, or the video opens with a
run of commercials in front of thirty children. GetVideo lets them save the video at home the
night before and play it from their own computer.

Dave

## How it works

Every video runs the same three stages:

1. **Download.** yt-dlp fetches the video and audio, up to the quality you set.
2. **Convert.** HandBrake re-encodes it with a preset so it plays anywhere and takes less space.
3. **Save.** The finished file moves to your folder, named after the video.

**Easy mode** is the default: paste a link and press **Get video**. It uses sensible settings
(up to 1080p, HandBrake's Fast 1080p30 preset, an mp4 in your Downloads folder).

**Advanced mode** shows every download and conversion option. Press **Save as default** and Easy
mode uses your settings from then on.

On first start GetVideo downloads the tools it needs (yt-dlp, HandBrakeCLI and ffmpeg) into its
own folder and keeps them up to date. It runs entirely on your Mac: no account, no upload, no
tracking.

## Install

Download from the [releases page](https://github.com/davewat/getvideo/releases/latest). Neither
download is notarized by Apple yet, so macOS blocks it until you clear the download flag in
Terminal, as shown below.

**The Mac app (recommended).** Download `GetVideo-…-macos.zip` and unzip it. Then:

    xattr -dr com.apple.quarantine ~/Downloads/GetVideo.app

Double-click GetVideo. The first start takes about a minute while the tools install. Needs
macOS 14 or later.

**The browser version.** Download `getvideo-…-macos-universal.zip` and unzip it. Then:

    xattr -d com.apple.quarantine ~/Downloads/getvideo
    ~/Downloads/getvideo

Your browser opens the app. Keep the Terminal window open while you use it.

## On the shoulders of giants

GetVideo is a thin layer. The hard work is done by open-source projects that volunteers have built
and maintained for years. If GetVideo is useful to you, the thanks belong to them.

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) does every download.
- [HandBrake](https://handbrake.fr) does every conversion.
- [FFmpeg](https://ffmpeg.org) joins video and audio, and both of the above rely on it.

GetVideo is an independent project and is not affiliated with or endorsed by any of them, or by
YouTube.

## For developers

Go is the only requirement; the web UI in `web/` is plain HTML, CSS and JavaScript embedded in
the binary.

    ./build.sh            # dist/getvideo, universal (Apple Silicon + Intel)
    ./build.sh native     # this machine's architecture only
    ./release.sh v1.2.3   # tag, build and publish a GitHub release

Flags: `-port 8765`, `-no-open`, `-data <dir>` (default `~/Library/Application Support/GetVideo`).

- `tools.go` installs and updates yt-dlp, HandBrakeCLI and ffmpeg.
- `jobs.go` is the queue: download, convert, save, with progress over server-sent events.
- `options.go` turns the form's options into command-line arguments.
- `server.go` is the HTTP API. It listens on localhost only.
- `web/js/schema.js` defines the form fields and defaults; add an option there.
- The website lives on the `web` branch.

### Native Mac app

`mac/` holds a native SwiftUI version that works the same way, with no browser or Terminal. It
needs Xcode and macOS 14 or later.

    ./mac/build.sh          # dist/GetVideo.app, universal
    ./mac/build.sh native   # this machine's architecture only

It shares the tools folder with the Go version and keeps its own settings and history. For
testing, `GETVIDEO_DATA=/some/folder` points it at a different data folder.

MIT licence.
