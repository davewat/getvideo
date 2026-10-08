import SwiftUI

// MARK: - Notice

/// The "Updating app" banner: what the tools are doing, or what went wrong with them.
struct NoticeBanner: View {
    @EnvironmentObject private var tools: ToolManager
    let isEasy: Bool

    private struct Notice {
        var busy = false
        var bad = false
        var title: String
        var text: String
        var retry: [ToolName] = []
    }

    private var notice: Notice? {
        guard tools.loaded else { return nil }
        let names = { (ts: [Tool]) in ts.map(\.name.rawValue).joined(separator: ", ") }
        let busy = tools.tools.filter(\.busy)
        let missing = tools.tools.filter { !$0.installed }
        let failed = tools.tools.filter { $0.error != nil && !$0.busy && (!$0.installed || $0.updateAvailable) }
        if !busy.isEmpty {
            let first = busy.contains { !$0.installed }
            return Notice(busy: true, title: first ? "Setting up GetVideo" : "Updating app",
                          text: first ? "Installing \(names(busy)). This takes about a minute the first time."
                              : "Updating \(names(busy)). You can keep adding videos.")
        }
        if !failed.isEmpty {
            return Notice(bad: true, title: "\(names(failed)) did not \(missing.isEmpty ? "update" : "install")",
                          text: failed[0].error ?? "", retry: failed.map(\.name))
        }
        if !missing.isEmpty, !isEasy {
            return Notice(bad: true, title: "\(names(missing)) not installed", text: "Install it from the Tools panel.")
        }
        return nil
    }

    var body: some View {
        if let notice {
            HStack(alignment: .center, spacing: 10) {
                if notice.busy {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                (Text(notice.title).fontWeight(.semibold) + Text("  ") + Text(notice.text))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !notice.retry.isEmpty {
                    SmallButton("Try again") { retry(notice.retry) }
                }
            }
            .padding(.vertical, 11)
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .background(Color.deck)
            .overlay(alignment: .leading) {
                Rectangle().fill(notice.bad ? Color.barRed : Color.barBlue).frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line, lineWidth: 1))
            .frame(maxWidth: isEasy ? 640 : .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .accessibilityElement(children: .contain)
        }
    }

    /// Installs every failed tool again, side by side.
    private func retry(_ names: [ToolName]) {
        for name in names {
            Task { await tools.install(name) }
        }
    }
}

// MARK: - Easy

/// The GetVideo page: a link box and one button, running with the saved defaults.
struct EasyView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Binding var expanded: Set<UUID>
    let changeSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    LinkSection()
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        PlanView(settings: settings.saved)
                        LinkButton("Change settings", action: changeSettings)
                    }
                    SubmitSection(isEasy: true)
                }
                .card()
                QueueCard(expanded: $expanded)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }
}

/// What a set of options will do, one phrase per stage.
struct PlanView: View {
    let settings: Settings

    private var items: [(stage: Stage, text: String)] {
        let d = settings.download
        let t = settings.transcode
        var items: [(Stage, String)] = [
            (.download, d.audioOnly ? "audio only, \(d.audioFormat)" : d.maxHeight != 0 ? "up to \(d.maxHeight)p" : "best quality"),
        ]
        if settings.converts {
            items.append((.convert, [t.preset.isEmpty ? "custom settings" : t.preset, t.container]
                    .filter { !$0.isEmpty }.joined(separator: ", ")))
        }
        items.append((.save, settings.output.dir.isEmpty ? "~/Downloads" : settings.output.dir))
        return items
    }

    var body: some View {
        FlowLayout(spacing: 18, lineSpacing: 6) {
            ForEach(items, id: \.stage) { item in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Swatch(stage: item.stage)
                    (Text(item.stage.label).fontWeight(.semibold).foregroundColor(Color.ink) + Text(" ") + Text(item.text))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.soft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
