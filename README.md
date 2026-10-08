# GetVideo

Single-binary macOS service: paste a YouTube link, download it with yt-dlp, transcode it with
HandBrakeCLI, and save it to a folder you choose. The UI is a web page served on `127.0.0.1:8765`.


## Build and run

    ./build.sh            # dist/getvideo, universal (Apple Silicon + Intel)
    ./build.sh native     # this machine's architecture only
    ./dist/getvideo       # opens the browser

Flags: `-port 8765`, `-no-open`, `-data <dir>` (default `~/Library/Application Support/GetVideo`).
After editing anything in `web/`, rebuild: the files are embedded in the binary.

## Layout
- `tools.go` installs/updates yt-dlp (checksum-verified), HandBrakeCLI (from the .dmg), ffmpeg (static build).
- `jobs.go` the queue: download -> transcode -> move; progress over SSE (`/api/events`); `jobs.json` history.
- `options.go` curated option structs -> CLI args, plus an "extra arguments" escape hatch.
- `server.go` HTTP API; binds localhost only, checks Host, requires `X-GetVideo: 1` on writes.
- `web/` the page: `index.html`, `style.css`, `js/app.js` (UI), `js/schema.js` (form fields and
  defaults; add an option here), `js/api.js`, `js/dom.js`.
