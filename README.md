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

GetVideo is not signed with Apple yet, so the first time you open it macOS asks you to allow it.
You only do this once.

1. **Download.** [Click here to download GetVideo](https://github.com/davewat/getvideo/releases/latest/download/GetVideo-mac-native.zip).
   Safari unzips it for you; in other browsers, double-click the zip in your Downloads folder.
2. **Copy it to your Applications folder.** Drag **GetVideo** from Downloads into **Applications**.
3. **Open it, and close the warning.** Double-click GetVideo. macOS says it could not verify the
   app. Click **Done** (on older versions of macOS the button is **Cancel** or **OK**). Do not
   click Move to Trash.
4. **Allow it.** Click the Apple menu, then **System Settings**, then **Privacy & Security**.
   Scroll down to **Security**. Next to "GetVideo was blocked", click **Open Anyway**.
5. **Enter your password.** macOS asks for your Mac password (or Touch ID) to confirm.
6. **Open GetVideo again.** Double-click it in Applications once more, and it opens.

From now on it opens like any other app. The first start takes about a minute
while it installs its tools. It needs macOS 14 or later.

**Prefer the browser version?** The Mac Go version runs in your browser instead.
[Download it](https://github.com/davewat/getvideo/releases/latest/download/getvideo-mac-go.zip),
unzip it, then in Terminal:

    xattr -d com.apple.quarantine ~/Downloads/getvideo
    ~/Downloads/getvideo

Keep the Terminal window open while you use it.

## Windows and Ubuntu (untested)

GetVideo is made for the Mac, and the Mac is the only place it has been tested. The browser
version is also built for Windows and Ubuntu, for anyone who wants to try it. These builds have
never been run on a real machine, so expect rough edges, and please
[report what you find](https://github.com/davewat/getvideo/issues). Both are for 64-bit Intel or
AMD computers.

**Windows Go version.** [Download it](https://github.com/davewat/getvideo/releases/latest/download/getvideo-windows-go.zip),
unzip it and double-click `getvideo.exe`. If Windows shows "Windows protected your PC", click
**More info**, then **Run anyway**. Your browser opens the app; keep the black window open while
you use it.

**Ubuntu Go version.** HandBrake has to be installed first, because GetVideo cannot install it on
Linux. [Download GetVideo](https://github.com/davewat/getvideo/releases/latest/download/getvideo-ubuntu-go.tar.gz),
then in a terminal:

    sudo apt install handbrake-cli
    tar -xzf ~/Downloads/getvideo-ubuntu-go.tar.gz
    ./getvideo

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

    ./build.sh            # every platform: dist/getvideo (macOS universal),
                          # dist/windows/getvideo.exe, dist/ubuntu/getvideo
    ./build.sh native     # this machine only
    ./release.sh v1.2.3   # tag, build and publish a GitHub release

Flags: `-port 8765`, `-no-open`, `-data <dir>` (default `~/Library/Application Support/GetVideo`
on macOS, `%AppData%\GetVideo` on Windows, `~/.local/share/getvideo` on Linux).

- `tools.go` installs and updates yt-dlp, HandBrakeCLI and ffmpeg.
- `platform_darwin.go`, `platform_windows.go` and `platform_linux.go` hold what differs per
  system: where each tool comes from, opening the browser, the folder chooser.
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
