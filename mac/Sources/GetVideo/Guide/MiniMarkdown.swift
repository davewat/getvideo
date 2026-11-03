import Foundation

/// A small Markdown to HTML converter for what the model writes: headings, paragraphs, lists, block
/// quotes, code, bold, italic and http(s) links. Every piece of text is HTML-escaped before any tag
/// is added, so nothing in the input can become markup.
enum MiniMarkdown {
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    private static let code = try! NSRegularExpression(pattern: "`([^`\n]+)`")
    private static let bold = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let italic = try! NSRegularExpression(pattern: #"(?<![\*\w])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\*\w])"#)
    private static let link = try! NSRegularExpression(pattern: #"\[([^\]\n]+)\]\((https?://[^)\s]+)\)"#)
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})\s+(.*?)\s*#*\s*$"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*[-*+]\s+(.*)$"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^\s*\d+[.)]\s+(.*)$"#)
    private static let rule = try! NSRegularExpression(pattern: #"^\s*([-*_])(\s*\1){2,}\s*$"#)

    private static func match(_ re: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    /// Inline formatting of one run of text.
    static func inline(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var at = 0
        for m in code.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += styled(ns.substring(with: NSRange(location: at, length: m.range.location - at)))
            out += "<code>" + escape(ns.substring(with: m.range(at: 1))) + "</code>"
            at = m.range.location + m.range.length
        }
        return out + styled(ns.substring(from: at))
    }

    /// Escapes first; the patterns then only ever add the fixed tags below.
    private static func styled(_ s: String) -> String {
        var t = escape(s)
        t = replace(link, in: t, with: "<a href=\"$2\">$1</a>")
        t = replace(bold, in: t, with: "<strong>$1</strong>")
        t = replace(italic, in: t, with: "<em>$1</em>")
        return t
    }

    static func render(_ markdown: String) -> String {
        var html = ""
        var paragraph: [String] = []
        var items: [String] = []
        var listTag = ""
        var quote: [String] = []

        func flush() {
            if !paragraph.isEmpty { html += "<p>" + inline(paragraph.joined(separator: " ")) + "</p>\n"; paragraph = [] }
            if !items.isEmpty {
                html += "<\(listTag)>" + items.map { "<li>" + inline($0) + "</li>" }.joined() + "</\(listTag)>\n"
                items = []
            }
            if !quote.isEmpty { html += "<blockquote>" + render(quote.joined(separator: "\n")) + "</blockquote>\n"; quote = [] }
        }

        var lines = markdown.components(separatedBy: "\n")[...]
        while let raw = lines.popFirst() {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                flush()
                var body: [String] = []
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") { body.append(next) }
                html += "<pre><code>" + escape(body.joined(separator: "\n")) + "</code></pre>\n"
            } else if trimmed.isEmpty {
                flush()
            } else if let h = match(heading, trimmed) {
                flush()
                html += "<h\(h[1].count)>" + inline(h[2]) + "</h\(h[1].count)>\n"
            } else if match(rule, trimmed) != nil {
                flush()
                html += "<hr>\n"
            } else if trimmed.hasPrefix(">") {
                if quote.isEmpty { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let b = match(bullet, line) ?? match(numbered, line) {
                let tag = match(bullet, line) != nil ? "ul" : "ol"
                if !items.isEmpty, tag != listTag { flush() } else if items.isEmpty { flush() }
                listTag = tag
                items.append(b[1])
            } else if !items.isEmpty {
                items[items.count - 1] += " " + trimmed   // a wrapped list item
            } else {
                if !quote.isEmpty { flush() }
                paragraph.append(trimmed)
            }
        }
        flush()
        return html
    }
}
