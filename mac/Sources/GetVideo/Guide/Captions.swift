import Foundation

/// One caption: when it starts and what is said.
struct CaptionCue: Equatable {
    var start: Double   // seconds
    var text: String
}

/// Reads yt-dlp's json3 captions and turns them into the transcript the model is given.
enum Captions {
    /// The cues in a json3 file, in order. Events without text (line breaks, window setup) are skipped.
    static func parseJSON3(_ data: Data) throws -> [CaptionCue] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else {
            throw JobError(message: "Could not read the captions file")
        }
        var cues: [CaptionCue] = []
        for event in events {
            guard let segs = event["segs"] as? [[String: Any]], let ms = (event["tStartMs"] as? NSNumber)?.doubleValue else { continue }
            let raw = segs.compactMap { $0["utf8"] as? String }.joined()
            let text = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !text.isEmpty { cues.append(CaptionCue(start: ms / 1000, text: text)) }
        }
        return cues
    }

    /// About `window` seconds of captions per line, each as `[123s] text`.
    static func formatTranscript(_ cues: [CaptionCue], window: Double = 20) -> String {
        var lines: [String] = []
        var current = ""
        var lineStart = 0.0
        for cue in cues {
            if current.isEmpty {
                lineStart = cue.start
                current = cue.text
            } else if cue.start - lineStart >= window {
                lines.append("[\(Int(lineStart))s] \(current)")
                lineStart = cue.start
                current = cue.text
            } else {
                current += " " + cue.text
            }
        }
        if !current.isEmpty { lines.append("[\(Int(lineStart))s] \(current)") }
        return lines.joined(separator: "\n")
    }

    /// Which of the json3 files yt-dlp wrote to use: plain English (`<id>.en.json3`) first, then
    /// whichever other English variant sorts first.
    static func pick(from names: [String]) -> String? {
        let files = names.filter { $0.hasSuffix(".json3") }.sorted()
        return files.first { $0.hasSuffix(".en.json3") } ?? files.first
    }
}
