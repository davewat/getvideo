import Foundation

/// Builds the guide's web page: everything the model and the video's metadata said is escaped, the
/// screenshots are embedded, and the page carries its own style sheet.
enum GuideHTML {
    private enum Piece {
        case markdown(String)
        case heading(level: Int, text: String, at: Int?)
        case shot(Int)
    }

    /// Splits the Markdown at its `##` headings (with the `{{AT}}` line after each) and its screenshots.
    private static func pieces(_ md: String) -> [Piece] {
        var out: [Piece] = []
        var buffer: [String] = []
        func flush() {
            let text = buffer.joined(separator: "\n")
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.markdown(text)) }
            buffer = []
        }
        func number(_ line: String, _ tag: String) -> Int? {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("{{\(tag):"), t.hasSuffix("}}") else { return nil }
            return Int(t.dropFirst(tag.count + 3).dropLast(2).trimmingCharacters(in: .whitespaces))
        }
        let lines = md.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let t = line.trimmingCharacters(in: .whitespaces)
            if let s = number(line, "SCREENSHOT") {
                flush()
                out.append(.shot(s))
            } else if let at = number(line, "AT") {
                _ = at   // an AT line not under a heading: nothing to attach it to
            } else if t.hasPrefix("##"), !t.hasPrefix("###") {
                flush()
                var next = i + 1
                while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
                let at = next < lines.count ? number(lines[next], "AT") : nil
                out.append(.heading(level: 2, text: String(t.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces), at: at))
                if at != nil { i = next }
            } else {
                buffer.append(line)
            }
            i += 1
        }
        flush()
        return out
    }

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func build(_ guide: ParsedGuide, meta: VideoMeta, images: [Int: Data], options: GuideOptions) -> String {
        let e = MiniMarkdown.escape
        var body = ""
        for piece in pieces(guide.markdown) {
            switch piece {
            case .markdown(let md):
                body += MiniMarkdown.render(md)
            case .heading(_, let text, let at):
                let h = "<h2>" + MiniMarkdown.inline(text) + "</h2>"
                if let at {
                    let when = e(clock(at))
                    let tc = meta.link(at: at).map { "<a class=\"tc\" href=\"\(e($0))\">\(when)</a>" } ?? "<span class=\"tc\">\(when)</span>"
                    body += "<div class=\"sec\">\(tc)\(h)</div>\n"
                } else {
                    body += "<div class=\"sec\"><span class=\"tc\"></span>\(h)</div>\n"
                }
            case .shot(let t):
                guard let data = images[t] else { continue }
                body += "<figure><img src=\"data:image/jpeg;base64,\(data.base64EncodedString())\" alt=\"Screenshot at \(e(clock(t)))\">"
                    + "<figcaption>\(e(clock(t)))</figcaption></figure>\n"
            }
        }
        var byline = [meta.channel, meta.duration > 0 ? clock(Int(meta.duration)) : ""].filter { !$0.isEmpty }.map(e).joined(separator: " · ")
        if !meta.pageURL.isEmpty { byline += (byline.isEmpty ? "" : " · ") + "<a href=\"\(e(meta.pageURL))\">Watch the video</a>" }
        let tldr = guide.tldr.isEmpty ? "" : "<div class=\"tldr\"><b>TL;DR</b>\(MiniMarkdown.render(guide.tldr))</div>\n"
        return """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <title>\(e(meta.title))</title>
        <style>\(css(dark: options.dark, large: options.largeText))</style></head>
        <body><main>
        <h1>\(e(meta.title))</h1>
        <p class="by">\(byline)</p>
        \(tldr)\(body)</main></body></html>
        """
    }

    static func css(dark: Bool, large: Bool) -> String {
        let (bg, ink, soft, rule, box) = dark
            ? ("#14181d", "#e6eaef", "#98a3b1", "#2c323b", "#1d2229")
            : ("#ffffff", "#17202b", "#5a6675", "#d5dbe2", "#f2f5f8")
        return """
        @page { size: A4; margin: 16mm 14mm 16mm 14mm }
        * { box-sizing: border-box }
        html, body { margin: 0; background: \(bg); -webkit-print-color-adjust: exact; print-color-adjust: exact }
        body { color: \(ink); font: \(large ? 13.5 : 11)pt/1.55 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif }
        main { padding: 0 }
        h1 { font-size: 1.9em; line-height: 1.2; margin: 0 0 .2em }
        h2 { font-size: 1.3em; margin: 0; line-height: 1.3 }
        .by { color: \(soft); margin: 0 0 1.2em }
        .tldr { background: \(box); border-left: 4px solid #2853c4; padding: .6em 1em; border-radius: 4px; margin: 0 0 1.4em }
        .tldr b { display: block; font-size: .8em; letter-spacing: .1em; color: \(soft); margin-bottom: .2em }
        .tldr p { margin: .3em 0 }
        .sec { display: flex; gap: 10px; align-items: baseline; margin: 1.6em 0 .5em; break-after: avoid }
        .tc { flex: none; width: 3.6em; font: .8em ui-monospace, Menlo, monospace; color: \(soft); text-decoration: none }
        a { color: #4a78e0 }
        p { margin: .5em 0; padding-left: 0 } .sec ~ p, .sec ~ ul, .sec ~ ol, .sec ~ pre, .sec ~ blockquote { margin-left: calc(3.6em + 10px) }
        ul, ol { margin: .5em 0; padding-left: 1.4em }
        li { margin: .2em 0 }
        code { font: .9em ui-monospace, Menlo, monospace; background: \(box); padding: .1em .3em; border-radius: 3px }
        pre { background: \(box); padding: .7em 1em; border-radius: 6px; white-space: pre-wrap; break-inside: avoid }
        pre code { background: none; padding: 0 }
        blockquote { border-left: 3px solid \(rule); margin: .6em 0; padding: 0 1em; color: \(soft) }
        hr { border: 0; border-top: 1px solid \(rule) }
        figure { margin: 1em 0 1em calc(3.6em + 10px); break-inside: avoid }
        img { max-width: 100%; border-radius: 6px; border: 1px solid \(rule); display: block }
        figcaption { color: \(soft); font: .75em ui-monospace, Menlo, monospace; margin-top: .3em }
        """
    }
}
