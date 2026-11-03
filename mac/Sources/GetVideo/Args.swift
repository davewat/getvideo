import Foundation

/// An option that cannot be turned into command-line arguments; the message is shown to the user.
struct ArgsError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Turns option structs into command-line arguments. A port of options.go.
enum Args {
    /// yt-dlp arguments for the options (not including the URL, output template or progress flags).
    static func download(_ o: DownloadOptions) throws -> [String] {
        var a: [String] = []
        if !o.customFormat.isEmpty {
            a += ["-f", o.customFormat]
        } else if o.audioOnly {
            a += ["-f", "ba/b"]
        } else if o.maxHeight > 0 {
            let h = String(o.maxHeight)
            a += ["-f", "bv*[height<=\(h)]+ba/b[height<=\(h)]"]
        } else {
            a += ["-f", "bv*+ba/b"]
        }
        if !o.formatSort.isEmpty { a += ["-S", o.formatSort] }
        if o.audioOnly {
            a += ["-x", "--audio-format", o.audioFormat.isEmpty ? "best" : o.audioFormat]
        } else if !o.mergeContainer.isEmpty {
            a += ["--merge-output-format", o.mergeContainer]
        }
        if o.noPlaylist { a.append("--no-playlist") }
        if o.subtitles { a.append("--write-subs") }
        if o.autoSubs { a.append("--write-auto-subs") }
        if o.subtitles || o.autoSubs {
            if !o.subLangs.isEmpty { a += ["--sub-langs", o.subLangs] }
            if o.embedSubs { a.append("--embed-subs") }
        }
        if o.embedMetadata { a.append("--embed-metadata") }
        if o.embedThumbnail { a.append("--embed-thumbnail") }
        if !o.cookiesBrowser.isEmpty { a += ["--cookies-from-browser", o.cookiesBrowser] }
        if !o.rateLimit.isEmpty { a += ["-r", o.rateLimit] }
        if !o.proxy.isEmpty { a += ["--proxy", o.proxy] }
        if !o.sponsorBlock.isEmpty { a += ["--sponsorblock-remove", o.sponsorBlock.joined(separator: ",")] }
        do {
            return a + (try split(o.extraArgs))
        } catch let e as ArgsError {
            throw ArgsError(message: "yt-dlp extra args: \(e.message)")
        }
    }

    /// HandBrakeCLI arguments after `-i`/`-o`.
    static func transcode(_ o: TranscodeOptions) throws -> [String] {
        var a: [String] = []
        if !o.preset.isEmpty { a += ["--preset", o.preset] }
        switch o.container {
        case "mp4": a += ["-f", "av_mp4"]
        case "mkv": a += ["-f", "av_mkv"]
        case "webm": a += ["-f", "av_webm"]
        default: break
        }
        if !o.encoder.isEmpty { a += ["-e", o.encoder] }
        if !o.encoderPreset.isEmpty { a += ["--encoder-preset", o.encoderPreset] }
        switch o.qualityMode {
        case "rf":
            a += ["-q", number(o.quality)]
        case "bitrate":
            guard o.videoBitrate > 0 else { throw ArgsError(message: "video bitrate must be > 0") }
            a += ["-b", String(o.videoBitrate)]
        default: break
        }
        if !o.framerate.isEmpty { a += ["-r", o.framerate] }
        if ["vfr", "cfr", "pfr"].contains(o.framerateMode) { a.append("--" + o.framerateMode) }
        if o.maxWidth > 0 { a += ["--maxWidth", String(o.maxWidth)] }
        if o.maxHeight > 0 { a += ["--maxHeight", String(o.maxHeight)] }
        if ["decomb", "yadif"].contains(o.deinterlace) { a.append("--" + o.deinterlace) }
        if !o.audioEncoder.isEmpty { a += ["-E", o.audioEncoder] }
        if o.audioBitrate > 0 { a += ["-B", String(o.audioBitrate)] }
        if o.allAudio { a.append("--all-audio") }
        if o.allSubs { a.append("--all-subtitles") }
        if o.webOptimize { a.append("--optimize") }
        try Trim.validate(o)
        do {
            return a + (try split(o.extraArgs))
        } catch let e as ArgsError {
            throw ArgsError(message: "HandBrake extra args: \(e.message)")
        }
    }

    /// yt-dlp arguments that save a video's English captions (json3) into `dir` as `<id>.<lang>.json3`
    /// and download nothing else. The URL comes last.
    static func captions(_ url: String, dir: URL) throws -> [String] {
        guard !url.isEmpty else { throw ArgsError(message: "a link is needed to get captions") }
        return ["--skip-download", "--write-subs", "--write-auto-subs", "--sub-langs", "en.*,en", "--sub-format", "json3",
                "--no-playlist", "--no-colors", "--newline", "-P", dir.path, "-o", "%(id)s.%(ext)s", url]
    }

    /// yt-dlp arguments that print one JSON line about the video (title, length, channel, a stream
    /// to take screenshots from) without downloading it.
    static func metadata(_ url: String) throws -> [String] {
        guard !url.isEmpty else { throw ArgsError(message: "a link is needed to read the video's details") }
        return ["-j", "--no-playlist", "--no-warnings", "--no-colors", "-f", "bv*[height<=720]/b[height<=720]/bv*/b", url]
    }

    /// Checks the guide options.
    static func guide(_ o: GuideOptions) throws {
        guard GuideOptions.styles.contains(o.style) else { throw ArgsError(message: "unknown guide style \"\(o.style)\"") }
        guard GuideOptions.providers.contains(o.provider) else { throw ArgsError(message: "unknown AI provider \"\(o.provider)\"") }
        guard o.maxShots >= 0 else { throw ArgsError(message: "the number of screenshots cannot be negative") }
        let u = o.effectiveBaseURL
        guard let url = URL(string: u), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            throw ArgsError(message: "the AI base URL \"\(u)\" must start with http:// or https://")
        }
    }

    /// Shell-style split: whitespace separated, with '...' and "..." quoting.
    static func split(_ s: String) throws -> [String] {
        var out: [String] = []
        var cur = ""
        var quote: Character?
        var started = false   // an empty quoted string ("") still makes an argument
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { cur.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
                started = true
            } else if c == " " || c == "\t" || c == "\n" {
                if started || !cur.isEmpty {
                    out.append(cur)
                    cur = ""
                    started = false
                }
            } else {
                cur.append(c)
            }
        }
        if quote != nil { throw ArgsError(message: "unterminated quote") }
        if started || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// Shortest decimal form, like Go's FormatFloat(v, 'f', -1, 64): 20 -> "20", 20.5 -> "20.5".
    private static func number(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
    }
}
