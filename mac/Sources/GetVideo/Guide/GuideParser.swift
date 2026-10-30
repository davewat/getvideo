import Foundation

/// The model's reply, split into its parts.
struct ParsedGuide: Equatable {
    var tldr = ""
    /// Markdown. Section starts are `{{AT: n}}` lines and pictures `{{SCREENSHOT: n}}` lines, with
    /// every time already clamped; screenshots over the limit are gone.
    var markdown = ""
    /// The screenshot times kept, in order.
    var shots: [Int] = []
}

/// Understands `[[TLDR]]`, `{{AT: n}}` and `{{SCREENSHOT: n}}`.
enum GuideParser {
    private static let marker = try! NSRegularExpression(pattern: #"^\s*\{\{\s*(AT|SCREENSHOT)\s*:\s*(\d+)\s*s?\s*\}\}\s*$"#,
                                                         options: [.caseInsensitive])

    /// `duration` is the video's length in seconds (0 = unknown, no upper limit). At most
    /// `maxShots` screenshots are kept, each at least `minGap` seconds from the others.
    static func parse(_ raw: String, duration: Double, maxShots: Int, minGap: Int = GuidePrompt.minShotGap) -> ParsedGuide {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // A reply wrapped in one code fence is unwrapped.
        if text.hasPrefix("```"), text.hasSuffix("```"), let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = ParsedGuide()
        if let open = text.range(of: "[[TLDR]]", options: .caseInsensitive) {
            if let close = text.range(of: "[[/TLDR]]", options: .caseInsensitive, range: open.upperBound..<text.endIndex) {
                out.tldr = String(text[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                text.removeSubrange(open.lowerBound..<close.upperBound)
            } else {   // never closed: the first paragraph is the summary
                let rest = String(text[open.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = rest.components(separatedBy: "\n\n")
                out.tldr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                text = parts.dropFirst().joined(separator: "\n\n")
            }
        }
        let limit = duration > 0 ? Int(duration) : Int.max
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let ns = line as NSString
            guard let m = marker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else {
                lines.append(line)
                continue
            }
            let kind = ns.substring(with: m.range(at: 1)).uppercased()
            let seconds = min(Int(ns.substring(with: m.range(at: 2))) ?? 0, limit)
            if kind == "AT" {
                lines.append("{{AT: \(seconds)}}")
            } else if out.shots.count < maxShots, !out.shots.contains(where: { abs($0 - seconds) < minGap }) {
                out.shots.append(seconds)
                lines.append("{{SCREENSHOT: \(seconds)}}")
            }
        }
        out.markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }
}
