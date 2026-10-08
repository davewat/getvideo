# GetVideo

Single-binary macOS service: paste a YouTube link, download it with yt-dlp, transcode it with
HandBrakeCLI, and save it to a folder you choose. The UI is a web page served on `127.0.0.1:8765`.


For educational use only. It was made for teachers who need to show short educational videos in
class without relying on the classroom's internet connection, and without the adverts.

## Built on

GetVideo is a thin layer over the work of others: [yt-dlp](https://github.com/yt-dlp/yt-dlp) does
every download, [HandBrake](https://handbrake.fr) does every conversion, and both rely on
[FFmpeg](https://ffmpeg.org). GetVideo is not affiliated with or endorsed by any of them.

Site: https://davewat.github.io/getvideo/ (the `web` branch).

## Build and run

    ./build.sh            # dist/getvideo, universal (Apple Silicon + Intel)
    ./build.sh native     # this machine's architecture only
    ./dist/getvideo       # opens the browser

Flags: `-port 8765`, `-no-open`, `-data <dir>` (default `~/Library/Application Support/GetVideo`).
After editing anything in `web/`, rebuild: the files are embedded in the binary.

## Easy and Advanced mode

The page opens in Easy mode: it installs or updates yt-dlp, HandBrakeCLI and ffmpeg on start
(showing an "Updating app" notice), and offers only a paste box. Advanced mode shows every
option; "Save as default" stores them in `settings.json` in the data directory, and Easy mode
runs with those saved defaults.

## Layout
- `tools.go` installs/updates yt-dlp (checksum-verified), HandBrakeCLI (from the .dmg), ffmpeg (static build).
- `jobs.go` the queue: download -> transcode -> move; progress over SSE (`/api/events`); `jobs.json` history.
- `options.go` curated option structs -> CLI args, plus an "extra arguments" escape hatch.
- `server.go` HTTP API; binds localhost only, checks Host, requires `X-GetVideo: 1` on writes.
- `web/` the page: `index.html`, `style.css`, `js/app.js` (UI), `js/schema.js` (form fields and
  defaults; add an option here), `js/api.js`, `js/dom.js`.
