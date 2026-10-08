import SwiftUI

/// The pages in the sidebar.
enum Pane: String, CaseIterable, Identifiable {
    case getVideo, advanced, about

    var id: Self { self }

    var title: String {
        switch self {
        case .getVideo: "GetVideo"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .getVideo: "play.rectangle"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }
}

/// The window: a sidebar for navigation and the selected page beside it.
struct ContentView: View {
    @EnvironmentObject private var tools: ToolManager
    @EnvironmentObject private var queue: JobQueue
    /// Always opens on GetVideo; GETVIDEO_PANE=advanced overrides that for testing.
    @State private var pane = Pane(rawValue: ProcessInfo.processInfo.environment["GETVIDEO_PANE"] ?? "") ?? .getVideo
    @StateObject private var form = LinkForm()
    /// Jobs whose log is showing. Kept here so it survives progress updates and page changes.
    @State private var expanded: Set<UUID> = []

    private var selection: Binding<Pane?> {
        Binding(get: { pane }, set: { if let p = $0 { pane = p } })
    }

    private var activeJobs: Int { queue.jobs.filter(\.status.isActive).count }
    private var toolProblems: Int { tools.loaded ? tools.tools.filter { !$0.installed || $0.error != nil }.count : 0 }

    var body: some View {
        NavigationSplitView {
            // Rows are identified by the Pane itself, which is what the selection holds.
            List(Pane.allCases, selection: selection) { p in
                Label(p.title, systemImage: p.symbol)
                    .badge(p == .getVideo ? activeJobs : p == .advanced ? toolProblems : 0)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if pane != .about { NoticeBanner(isEasy: pane == .getVideo) }
                switch pane {
                case .getVideo: EasyView(expanded: $expanded) { pane = .advanced }
                case .advanced: AdvancedView(expanded: $expanded)
                case .about: AboutPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(Color.ink)
            .background(Color.bay)
            .navigationTitle(pane.title)
        }
        .environmentObject(form)
        .task {
            // Show what is installed at once, then install what is missing and update what is stale.
            await tools.refresh(checkLatest: false)
            await tools.autoUpdate()
        }
    }
}
