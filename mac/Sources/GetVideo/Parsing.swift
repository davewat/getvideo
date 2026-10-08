import Foundation

/// Pure helpers shared by ToolManager and JobQueue; no actor, so tests call them directly.
enum Parsing {
    // MARK: File names

    /// Makes a title safe to use as a file name: no `/`, `:` or control characters, no leading
    /// dots, at most 180 bytes, never empty.
    static func sanitize(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            scalars.append(u == "/" || u == ":" || u.value < 0x20 ? "-" : u)
        }
        var out = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        if out.isEmpty { out = "video" }
        while out.utf8.count > 180 { out.removeLast() }
        return out
    }

    /// The file name (before sanitizing, without extension) for one downloaded file: the custom
    /// name when there is one and only one file, else the video title, else the downloaded
    /// file's own name (the video id).
    static func outputName(custom: String, title: String, url: String, source: URL, fileCount: Int) -> String {
        if !custom.isEmpty && fileCount == 1 { return custom }
        if !title.isEmpty && title != url && fileCount == 1 { return title }
        return source.deletingPathExtension().lastPathComponent
    }

    /// `dir/name.ext`, or the first free `dir/name (n).ext` when that is taken and overwrite is off.
    /// `ext` includes its dot, or is empty.
    static func destination(dir: URL, name: String, ext: String, overwrite: Bool) -> URL {
        var dst = dir.appendingPathComponent(name + ext)
        if overwrite { return dst }
        var n = 1
        while FileManager.default.fileExists(atPath: dst.path) {
            dst = dir.appendingPathComponent("\(name) (\(n))\(ext)")
            n += 1
        }
        return dst
    }

    /// Moves `src` into `dir` under `name`, keeping its extension, and returns where it went.
    static func move(_ src: URL, into dir: URL, name: String, overwrite: Bool) throws -> URL {
        let ext = src.pathExtension.isEmpty ? "" : "." + src.pathExtension
        let dst = destination(dir: dir, name: name, ext: ext, overwrite: overwrite)
        let fm = FileManager.default
        do {
            if overwrite, fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: src, to: dst)   // copies when the folder is on another volume
        } catch {
            throw ProcError(message: "Could not save to \(dst.path): \(error.localizedDescription)")
        }
        return dst
    }

    // MARK: Tool output

    /// Understands `HandBrakeCLI --preset-list`: a "Category/" header, presets indented four
    /// spaces, their descriptions indented eight.
    static func presetList(_ s: String) -> [PresetGroup] {
        var groups: [PresetGroup] = []
        for raw in s.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if line.hasPrefix("    ") {
                if line.hasPrefix("        ") { continue }   // description
                let name = line.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, !groups.isEmpty { groups[groups.count - 1].presets.append(name) }
            } else if line.hasSuffix("/"), let first = line.unicodeScalars.first,
                      !CharacterSet.whitespaces.contains(first) {
                groups.append(PresetGroup(category: String(line.dropLast()), presets: []))
            }
        }
        return groups
    }

    struct HBProgress: Equatable {
        var percent: Double
        var fps: String?   // nil until HandBrake has an average to report
        var eta: String?
    }

    private static let hbRegex = try! NSRegularExpression(
        pattern: #"Encoding: task \d+ of \d+, ([\d.]+) %(?: \(([\d.]+) fps, avg [\d.]+ fps, ETA (\S+)\))?"#)

    /// Parses a HandBrakeCLI progress line; nil for any other line.
    static func handBrakeProgress(_ line: String) -> HBProgress? {
        let ns = line as NSString
        guard let m = hbRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        return HBProgress(percent: Double(group(1) ?? "") ?? 0, fps: group(2), eta: group(3))
    }

    struct YTProgress: Equatable {
        var percent: Double?   // nil when yt-dlp does not know the size yet
        var speed: String
        var eta: String
    }

    /// Parses the body of a `GVPROG <percent>|<speed>|<eta>` line.
    static func ytdlpProgress(_ body: String) -> YTProgress? {
        let f = body.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        guard f.count == 3 else { return nil }
        let pct = f[0].hasSuffix("%") ? String(f[0].dropLast()) : f[0]
        return YTProgress(percent: Double(pct), speed: f[1], eta: f[2])
    }

    // MARK: Installing

    /// Finds an asset's hash in a `SHA2-256SUMS` file ("<hash>  <name>" or "<hash> *<name>" lines).
    static func checksum(in sums: String, asset: String) -> String? {
        for line in sums.components(separatedBy: .newlines) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count == 2 else { continue }
            let name = fields[1].hasPrefix("*") ? String(fields[1].dropFirst()) : fields[1]
            if name == asset { return fields[0] }
        }
        return nil
    }

    /// The ffmpeg build server redirects to `/download/macos/<arch>/<build>_<version>/ffmpeg.zip`;
    /// the version is the second-to-last path segment.
    static func ffmpegVersion(fromLocation location: String) -> String? {
        let parts = location.components(separatedBy: "/")
        guard parts.count >= 2, !parts[parts.count - 2].isEmpty else { return nil }
        return parts[parts.count - 2]
    }
}
