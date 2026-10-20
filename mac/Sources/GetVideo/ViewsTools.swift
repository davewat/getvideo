import SwiftUI

/// The Tools panel (Advanced only): what is installed next to what is newest, and updating by hand.
struct ToolsCard: View {
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var updater: AppUpdater

    private var anyBusy: Bool { tools.tools.contains(where: \.busy) }
    private var checking: Bool { tools.checking || updater.state == .checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Tools") {
                HStack(spacing: 8) {
                    if tools.updatesAvailable > 1 && !updater.updateAvailable {
                        SmallButton("Update All") { Task { await tools.updateAll() } }
                            .disabled(anyBusy)
                    }
                    Button {
                        Task {
                            async let tools: Void = self.tools.checkForUpdates()
                            async let app: Void = updater.check()
                            _ = await (tools, app)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if checking { ProgressView().controlSize(.small) }
                            Text(checking ? "Checking…" : "Check for Updates")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(checking)
                }
            }
            if let summary {
                Text(summary.text)
                    .font(.system(size: 12))
                    .foregroundStyle(summary.color)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            VStack(alignment: .leading, spacing: 9) {
                AppRow()
                ForEach(tools.tools) { tool in
                    Hairline()
                    ToolRow(tool: tool)
                }
            }
        }
        .card()
    }

    /// One line saying how the last check went.
    private var summary: (text: String, color: Color)? {
        if checking { return ("Looking for newer versions…", .soft) }
        let failed = tools.tools.filter { $0.checkError != nil }
        if !failed.isEmpty, failed.count == tools.tools.count {
            return ("Could not check for updates. \(failed[0].checkError ?? "")", .barRed)
        }
        guard let when = tools.lastChecked else {
            return ("Press Check for Updates to see the newest versions.", .soft)
        }
        let time = when.formatted(date: .omitted, time: .shortened)
        let n = tools.updatesAvailable + (updater.updateAvailable ? 1 : 0)
        var text = n == 0 ? "Everything is up to date. Checked at \(time)."
            : "\(n) update\(n == 1 ? "" : "s") available. Checked at \(time)."
        if !failed.isEmpty { text += " Could not check \(failed.map(\.name.rawValue).joined(separator: ", "))." }
        return (text, failed.isEmpty ? (n == 0 ? .barGreen : .soft) : .soft)
    }
}

struct ToolRow: View {
    @EnvironmentObject private var tools: ToolManager
    let tool: Tool

    private enum State { case busy, missing, update, ok }

    private var state: State {
        tool.busy ? .busy : !tool.installed ? .missing : tool.updateAvailable ? .update : .ok
    }

    private var dot: Color {
        switch state {
        case .busy: .barBlue
        case .missing: .barRed
        case .update: .barYellow
        case .ok: .barGreen
        }
    }

    /// The verdict, shown beside the buttons: only when it is known.
    private var verdict: (text: String, color: Color)? {
        switch state {
        case .busy: ("Installing…", .soft)
        case .missing: ("Not installed", .barRed)
        case .update: ("Update available", .barYellow)
        case .ok: tool.latest.isEmpty ? nil : ("Up to date", .barGreen)
        }
    }

    private var installedText: String { tool.installed ? (tool.version.isEmpty ? "installed" : tool.version) : "not installed" }

    private var latestText: String {
        if !tool.latest.isEmpty { return tool.latest }
        return tool.checkError != nil ? "could not check" : "not checked yet"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).padding(.top, 6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name.rawValue).fontWeight(.semibold)
                versionLine("Installed", installedText)
                versionLine("Latest", latestText, highlight: state == .update)
                if let error = tool.checkError, tool.latest.isEmpty {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.barRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = tool.error, !tool.busy {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.barRed)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(alignment: .trailing, spacing: 4) {
                if let verdict {
                    Text(verdict.text).font(.system(size: 11)).foregroundStyle(verdict.color)
                }
                if tool.busy {
                    ProgressView().controlSize(.small)
                } else {
                    action
                }
            }
        }
    }

    private func versionLine(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.soft).frame(width: 58, alignment: .leading)
            Text(value)
                .font(.timecode())
                .foregroundStyle(highlight ? Color.ink : Color.soft)
                .fontWeight(highlight ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .ok: LinkButton("Reinstall", action: install).accessibilityLabel("Reinstall \(tool.name.rawValue)")
        case .update:
            Button("Update to \(tool.latest)", action: install)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Update \(tool.name.rawValue) to \(tool.latest)")
        case .busy, .missing: SmallButton("Install", action: install).accessibilityLabel("Install \(tool.name.rawValue)")
        }
    }

    private func install() {
        Task { await tools.install(tool.name) }
    }
}
