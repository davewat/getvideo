import SwiftUI

// The parts of the form both modes share: the link box, the error line and the primary button.

/// The link box's text and the form's error line. One instance for the window, so a link typed
/// in one mode is still there after switching to the other.
@MainActor
final class LinkForm: ObservableObject {
    @Published var text = ""
    /// "Not added: ..." or "Defaults not saved: ...", shown above the primary button.
    @Published var error: String?

    /// The links in the box: split on any whitespace, empties ignored.
    var urls: [String] { text.split(whereSeparator: \.isWhitespace).map(String.init) }
}

/// The message to show for a thrown error. The core's errors are all `LocalizedError`s whose
/// description is already written for the user.
func userMessage(_ error: Error) -> String { error.localizedDescription }

/// "VIDEO LINK", the editor and its hint.
struct LinkSection: View {
    @EnvironmentObject private var form: LinkForm

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SlateText("Video link")
            LinkEditor(text: $form.text)
                .frame(height: 68)
                .overlay(alignment: .topLeading) {
                    if form.text.isEmpty {
                        Text(verbatim: "https://www.youtube.com/watch?v=…")
                            .font(.timecode(13))
                            .foregroundStyle(Color.soft.opacity(0.75))
                            .padding(.horizontal, LinkEditor.inset.width + 5) // + the text view's own line padding
                            .padding(.vertical, LinkEditor.inset.height)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(Color.well, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line, lineWidth: 1))
            Text("Paste one link, or several on separate lines.").hint()
        }
    }
}

/// A plain multi-line monospaced editor. An AppKit text view rather than `TextEditor` so that
/// smart dashes, quotes and spelling correction can never rewrite a pasted link.
struct LinkEditor: NSViewRepresentable {
    static let inset = CGSize(width: 9, height: 10)

    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.string = text
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.textContainerInset = Self.inset
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.setAccessibilityLabel("Video link")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if view.string != text { view.string = text }
        // Re-resolved on every update so the text follows a light/dark switch.
        _ = context.environment.colorScheme
        view.textColor = NSColor(Color.ink)
        view.insertionPointColor = NSColor(Color.ink)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// The form's error line and its one primary button. Cmd-Return presses the button.
struct SubmitSection: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: JobQueue
    @EnvironmentObject private var form: LinkForm
    let isEasy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = form.error {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.barRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Button(tools.ready ? (isEasy ? "Get video" : "Add to queue") : "Getting ready…", action: submit)
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!tools.ready) // held until every tool is present
        }
    }

    private func submit() {
        let urls = form.urls
        guard !urls.isEmpty else { return }
        form.error = nil
        do {
            // Easy mode never sends unsaved Advanced edits.
            try queue.add(urls: urls, settings: isEasy ? settings.saved : settings.draft)
            form.text = ""
            if !isEasy { settings.draft.output.filename = "" }
        } catch {
            form.error = "Not added: \(userMessage(error))"
        }
    }
}
