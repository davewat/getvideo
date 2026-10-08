import SwiftUI

/// The Tools panel (Advanced only): what is installed, and installing or updating it by hand.
struct ToolsCard: View {
    @EnvironmentObject private var tools: ToolManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Tools") {
                LinkButton("Check for updates") {
                    Task { await tools.refresh(checkLatest: true) }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(tools.tools) { tool in
                    if tool.id != tools.tools.first?.id { Hairline() }
                    ToolRow(tool: tool)
                }
            }
        }
        .card()
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

    private var status: String {
        switch state {
        case .busy: "Installing…"
        case .missing: "Not installed"
        case .update: "\(tool.version) → \(tool.latest)"
        case .ok: tool.version
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name.rawValue).fontWeight(.semibold)
                Text(status)
                    .font(.timecode())
                    .foregroundStyle(Color.soft)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
            action.disabled(tool.busy)
        }
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .ok: LinkButton("Reinstall", action: install).accessibilityLabel("Reinstall \(tool.name.rawValue)")
        case .update: SmallButton("Update", action: install).accessibilityLabel("Update \(tool.name.rawValue)")
        case .busy, .missing: SmallButton("Install", action: install).accessibilityLabel("Install \(tool.name.rawValue)")
        }
    }

    private func install() {
        Task { await tools.install(tool.name) }
    }
}
