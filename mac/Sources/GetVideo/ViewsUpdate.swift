import SwiftUI

/// Tells people a new version of GetVideo is out and offers to install it and restart.
struct UpdateBanner: View {
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var queue: JobQueue
    let isEasy: Bool

    /// Restarting would cut a video off in the middle.
    private var videosRunning: Bool { queue.jobs.contains { $0.status.isActive } }

    private struct Banner {
        var busy = false
        var bad = false
        var title: String
        var text: String
    }

    private var banner: Banner? {
        switch updater.state {
        case .available(let v):
            Banner(title: "GetVideo \(v) is available",
                   text: videosRunning ? "Update when the videos in the queue have finished."
                       : "You have \(updater.currentVersion). Updating restarts GetVideo.")
        case .downloading:
            Banner(busy: true, title: "Downloading the update", text: "GetVideo restarts when it is ready.")
        case .installing:
            Banner(busy: true, title: "Installing the update", text: "GetVideo restarts in a moment.")
        case .failed(let message):
            Banner(bad: true, title: "GetVideo did not update", text: message)
        default:
            nil
        }
    }

    var body: some View {
        if let banner {
            HStack(alignment: .center, spacing: 10) {
                if banner.busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
                (Text(banner.title).fontWeight(.semibold) + Text("  ") + Text(banner.text))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if updater.updateAvailable {
                    Button("Update and Restart") { Task { await updater.installAndRestart() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(videosRunning)
                } else if case .failed = updater.state {
                    SmallButton("Dismiss") { updater.dismissFailure() }
                }
            }
            .padding(.vertical, 11)
            .padding(.leading, 20)
            .padding(.trailing, 16)
            .background(Color.deck)
            .overlay(alignment: .leading) {
                Rectangle().fill(banner.bad ? Color.barRed : Color.barGreen).frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line, lineWidth: 1))
            .frame(maxWidth: isEasy ? 640 : .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .accessibilityElement(children: .contain)
        }
    }
}

/// GetVideo itself, as the first row of the Tools panel: this version next to the newest.
struct AppRow: View {
    @EnvironmentObject private var updater: AppUpdater
    @EnvironmentObject private var queue: JobQueue

    private var videosRunning: Bool { queue.jobs.contains { $0.status.isActive } }

    private var latestText: String {
        if !updater.latestVersion.isEmpty { return updater.latestVersion }
        if case .failed = updater.state { return "could not check" }
        return "not checked yet"
    }

    private var verdict: (text: String, color: Color)? {
        switch updater.state {
        case .available: ("Update available", .barYellow)
        case .downloading, .installing: ("Updating…", .soft)
        case .upToDate: ("Up to date", .barGreen)
        default: nil
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(updater.updateAvailable ? Color.barYellow : Color.barGreen).frame(width: 8, height: 8)
                .padding(.top, 6).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("GetVideo").fontWeight(.semibold)
                line("Installed", updater.currentVersion)
                line("Latest", latestText, highlight: updater.updateAvailable)
                if case .failed(let message) = updater.state {
                    Text(message).font(.system(size: 12)).foregroundStyle(Color.barRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(alignment: .trailing, spacing: 4) {
                if let verdict { Text(verdict.text).font(.system(size: 11)).foregroundStyle(verdict.color) }
                if updater.busy {
                    ProgressView().controlSize(.small)
                } else if case .available(let v) = updater.state {
                    Button("Update to \(v) and Restart") { Task { await updater.installAndRestart() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(videosRunning)
                        .accessibilityLabel("Update GetVideo to \(v) and restart")
                    if videosRunning { Text("Wait for the queue to finish.").font(.system(size: 11)).foregroundStyle(Color.soft) }
                }
            }
        }
    }

    private func line(_ label: String, _ value: String, highlight: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.soft).frame(width: 58, alignment: .leading)
            Text(value)
                .font(.timecode())
                .foregroundStyle(highlight ? Color.ink : Color.soft)
                .fontWeight(highlight ? .semibold : .regular)
        }
    }
}
