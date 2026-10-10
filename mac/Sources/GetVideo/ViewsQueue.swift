import SwiftUI

/// The queue: every job, newest first.
struct QueueCard: View {
    @EnvironmentObject private var queue: JobQueue
    /// Jobs whose "Details" log is open.
    @Binding var expanded: Set<UUID>

    var body: some View {
        let jobs = Array(queue.jobs.reversed())
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Queue") {
                if jobs.contains(where: { !$0.status.isActive }) {
                    LinkButton("Clear finished") { queue.clearFinished() }
                }
            }
            if jobs.isEmpty {
                Text("No videos yet. Paste a link and it shows up here.")
                    .foregroundStyle(Color.soft)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(jobs) { job in
                        if job.id != jobs.first?.id { Hairline() }
                        JobRow(job: job, showLog: Binding(
                            get: { expanded.contains(job.id) },
                            set: { if $0 { expanded.insert(job.id) } else { expanded.remove(job.id) } }))
                    }
                }
            }
        }
        .card()
    }
}

/// One job: title, status line, timeline, error, finished files, actions and the log.
struct JobRow: View {
    @EnvironmentObject private var queue: JobQueue
    let job: Job
    @Binding var showLog: Bool

    /// "Downloading 42% · 6.1MiB/s · 00:12 left", or just the status for stages without progress.
    private var statusLine: String {
        guard job.status == .downloading || job.status == .converting else { return job.status.label }
        return ["\(job.status.label) \(String(format: "%.0f", job.percent))%", job.speed, job.eta.isEmpty ? "" : "\(job.eta) left"]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var statusColor: Color {
        switch job.status {
        case .done: .barGreen
        case .failed: .barRed
        default: .soft
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(job.url)
                Text(statusLine)
                    .font(.timecode())
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
            Timeline(job: job)
            if let error = job.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.barRed)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // A download kept for a conversion that did not finish: "Try again" continues from it.
            if !job.status.isActive, job.status != .done, let kept = job.downloads.first {
                Text("Download kept (\((kept as NSString).lastPathComponent)). Try again continues from the conversion.").hint()
            }
            ForEach(job.outputs, id: \.self) { path in
                OutputRow(path: path)
            }
            HStack(spacing: 12) {
                if job.status.isActive {
                    SmallButton("Cancel") { queue.cancel(job.id) }
                }
                if job.status == .failed || job.status == .canceled {
                    SmallButton("Try again") { queue.retry(job.id) }
                }
                if !job.status.isActive {
                    LinkButton("Remove") { queue.remove(job.id) }
                }
                Spacer(minLength: 0)
                LinkButton("Details") { showLog.toggle() }
                    .accessibilityValue(showLog ? "Shown" : "Hidden")
            }
            if showLog {
                JobLog(lines: job.log)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The job's timeline: one segment per stage, filled in that stage's colour as the stage runs.
struct Timeline: View {
    let job: Job

    /// The running stage, if any.
    private var current: Stage? {
        switch job.status {
        case .downloading: .download
        case .converting: .convert
        case .saving: .save
        default: nil
        }
    }

    private var stages: [Stage] {
        if !job.source.isEmpty { return [.convert, .save] } // a file on disk is never downloaded
        return job.settings.converts ? [.download, .convert, .save] : [.download, .save]
    }

    /// 0...1: full once the stage is behind us, the job's percentage while it runs. Saving has
    /// no progress of its own, so it shows full for as long as it lasts.
    private func fill(_ stage: Stage) -> Double {
        let order = Stage.allCases
        guard let index = order.firstIndex(of: stage) else { return 0 }
        if job.status == .done { return 1 }
        guard let current, let at = order.firstIndex(of: current) else { return 0 }
        if at > index { return 1 }
        if at < index { return 0 }
        return stage == .save ? 1 : min(1, max(0, job.percent / 100))
    }

    private var accessibilityValue: String {
        switch job.status {
        case .downloading, .converting: "\(job.status.label), \(Int(job.percent.rounded())) percent"
        default: job.status.label
        }
    }

    var body: some View {
        let dead = job.status == .failed || job.status == .canceled
        WeightedRow(spacing: 3) {
            ForEach(stages, id: \.self) { stage in
                let fill = fill(stage)
                let active = stage == current
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.well)
                        .overlay(alignment: .leading) {
                            GeometryReader { geo in
                                Rectangle()
                                    .fill(dead ? Color.soft.opacity(0.5) : stage.color)
                                    .frame(width: geo.size.width * fill)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .strokeBorder(!dead && (active || fill >= 1) ? stage.color : Color.line, lineWidth: 1))
                        .frame(height: 8)
                        .animation(.linear(duration: 0.25), value: fill)
                    Text(stage.label.uppercased())
                        .font(.slate(10))
                        .tracking(1)
                        .foregroundStyle(active ? Color.ink : Color.soft)
                        .lineLimit(1)
                }
                .rowWeight(stage == .save ? 0.45 : 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(accessibilityValue)
    }
}

/// A finished file: its name, the folder it is in, and a way to it.
struct OutputRow: View {
    let path: String

    var body: some View {
        let url = URL(fileURLWithPath: path)
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                Text(url.deletingLastPathComponent().path + "/")
                    .font(.timecode(11))
                    .foregroundStyle(Color.soft)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .help(path)
            .frame(maxWidth: .infinity, alignment: .leading)
            SmallButton("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

/// The tools' own output for a job, newest lines at the bottom.
struct JobLog: View {
    let lines: [String]
    /// Enough to see what went wrong without laying out an hour of progress lines on every update.
    private let shown = 500

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "No output yet." : lines.suffix(shown).joined(separator: "\n"))
                .font(.timecode(11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxHeight: 200)
        .background(Color.well, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.line, lineWidth: 1))
        .accessibilityLabel("Details")
    }
}
