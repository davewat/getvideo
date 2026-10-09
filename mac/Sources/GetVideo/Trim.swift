import Foundation

/// Shortening a video. HandBrake can start and stop encoding at a point in time, so "shorten to
/// three hours" or "keep 25%" is a start offset and a length for `--start-at` and `--stop-at`.
/// A port of trim.go.
enum Trim {
    /// Reads a length of time as people write it: "3:00:00" (hours), "90:00" (minutes and seconds),
    /// or with units: "3h", "90m", "45s", "1h30m". A bare number is refused, because "3" could as
    /// easily mean hours as minutes.
    static func parseClock(_ input: String) -> Double? {
        let s = input.lowercased().filter { !$0.isWhitespace }
        if s.isEmpty { return nil }
        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 3 else { return nil }
            var total = 0.0
            for p in parts {
                guard let n = Double(p), n >= 0, !p.isEmpty else { return nil }
                total = total * 60 + n
            }
            return total
        }
        let number = #"(\d+(?:\.\d+)?)"#
        guard let re = try? NSRegularExpression(pattern: "^(?:\(number)h)?(?:\(number)m)?(?:\(number)s)?$"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        var total = 0.0
        for (group, unit) in [(1, 3600.0), (2, 60.0), (3, 1.0)] {
            if let r = Range(m.range(at: group), in: s), let n = Double(s[r]) { total += n * unit }
        }
        return total > 0 ? total : nil
    }

    /// Seconds as H:MM:SS.
    static func clockString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    /// The length of the first title in HandBrakeCLI `--scan` output ("  + duration: 12:34:56").
    static func scanDuration(_ output: String) -> Double? {
        for line in output.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("+ duration: ") else { continue }
            let parts = t.dropFirst("+ duration: ".count).split(separator: ":").compactMap { Double($0) }
            if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        }
        return nil
    }

    /// Rejects shortening settings that could not be applied.
    static func validate(_ o: TranscodeOptions) throws {
        switch o.trimMode {
        case "":
            return
        case "duration":
            if parseClock(o.trimLength) == nil { throw ArgsError(message: "shorten: enter a length like 3:00:00, 90:00 or 3h") }
        case "percent":
            if !(o.trimPercent > 0 && o.trimPercent <= 100) {
                throw ArgsError(message: "shorten: the percentage to keep must be between 1 and 100")
            }
        default:
            throw ArgsError(message: "shorten: unknown mode \"\(o.trimMode)\"")
        }
        if !["", "first", "last", "middle"].contains(o.trimKeep) {
            throw ArgsError(message: "shorten: unknown part to keep \"\(o.trimKeep)\"")
        }
    }

    /// True when the video's length must be read before the cut can be worked out. Keeping the
    /// first part of a fixed length does not need it: HandBrake just stops after that long.
    static func needsScan(_ o: TranscodeOptions) -> Bool {
        o.trimMode == "percent" || (o.trimMode == "duration" && !["", "first"].contains(o.trimKeep))
    }

    /// Which part to keep: where it starts and how long it is, in seconds. `total` is the video's
    /// length (ignored when `needsScan` is false). Nil when nothing is cut, either because
    /// shortening is off or because the video is already no longer than asked for.
    static func window(_ o: TranscodeOptions, total: Double) -> (start: Double, length: Double)? {
        let want: Double
        switch o.trimMode {
        case "duration": want = parseClock(o.trimLength) ?? 0
        case "percent": want = total * o.trimPercent / 100
        default: return nil
        }
        if want <= 0 || (total > 0 && want >= total) { return nil }
        var start = 0.0
        switch o.trimKeep {
        case "last": start = total - want
        case "middle": start = (total - want) / 2
        default: break
        }
        return (start.rounded(.down), want.rounded())
    }

    /// HandBrakeCLI's arguments for keeping a stretch of the video. `--stop-at` counts from the
    /// start point, so it is the length kept.
    static func args(start: Double, length: Double) -> [String] {
        var a: [String] = []
        if start > 0 { a += ["--start-at", "duration:\(Int(start))"] }
        return a + ["--stop-at", "duration:\(Int(length))"]
    }
}
