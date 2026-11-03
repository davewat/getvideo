import SwiftUI

/// The GetPDF page: a link box and one button that writes a PDF guide from the video's captions.
struct PDFView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: JobQueue
    @EnvironmentObject private var form: LinkForm
    @Binding var expanded: Set<UUID>
    let changeSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        SlateText("Video link")
                        LinkBox(text: $form.pdfText)
                        Text("Paste one link, or several on separate lines. The video needs captions.").hint()
                        Text("An AI model reads the captions and writes a PDF guide with screenshots. Needs your API key: see Advanced > PDF Guides.").hint()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        PlanView(settings: settings.saved, guide: true)
                        LinkButton("Change settings", action: changeSettings)
                    }
                    if let error = form.pdfError {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.barRed)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Button(tools.ready ? "Make PDF" : "Getting ready…", action: submit)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!tools.ready)
                }
                .card()
                QueueCard(expanded: $expanded)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }

    private func submit() {
        let urls = form.pdfURLs
        guard !urls.isEmpty else { return }
        form.pdfError = nil
        do {
            try queue.addGuide(urls: urls, settings: settings.saved)
            form.pdfText = ""
        } catch {
            form.pdfError = "Not added: \(userMessage(error))"
        }
    }
}
