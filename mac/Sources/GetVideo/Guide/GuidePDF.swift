import AppKit
import WebKit

/// Prints the guide's page to an A4 PDF with the system's web engine; no browser is downloaded.
@MainActor
enum GuidePDF {
    static let a4 = NSSize(width: 595.28, height: 841.89)

    /// Waits for the page to load, then for the print job to finish.
    private final class Loader: NSObject, WKNavigationDelegate {
        private var loaded: CheckedContinuation<Void, Error>?
        private var printed: CheckedContinuation<Bool, Never>?

        func load(_ html: String, in web: WKWebView) async throws {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                loaded = c
                web.loadHTMLString(html, baseURL: nil)
            }
        }

        func print(_ op: NSPrintOperation, in window: NSWindow) async -> Bool {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                printed = c
                op.runModal(for: window, delegate: self, didRun: #selector(didRun(_:success:contextInfo:)), contextInfo: nil)
            }
        }

        @objc func didRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            printed?.resume(returning: success)
            printed = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }

        private func finish(_ error: Error?) {
            guard let c = loaded else { return }
            loaded = nil
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
    }

    /// Writes `html` as a paginated A4 PDF at `url`.
    static func render(html: String, to url: URL) async throws {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false   // the page is only text and pictures
        let web = WKWebView(frame: NSRect(origin: .zero, size: a4), configuration: config)
        let loader = Loader()
        web.navigationDelegate = loader
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: a4), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        defer { window.contentView = nil }
        do {
            try await loader.load(html, in: web)
        } catch {
            throw JobError(message: "Could not lay out the guide: \(error.localizedDescription)")
        }

        let info = NSPrintInfo()
        info.paperSize = a4
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let op = web.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(origin: .zero, size: a4)
        let ok = await loader.print(op, in: window)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard ok, size > 0 else { throw JobError(message: "Could not make the PDF") }
    }
}
