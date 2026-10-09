import Combine
import Foundation

/// Why a job could not be queued or finished; the message is shown to the user.
struct JobError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Runs jobs one at a time, oldest first: download -> convert -> save. A port of jobs.go.
@MainActor
final class JobQueue: ObservableObject {
    /// Oldest first. The UI shows them newest first.
    @Published private(set) var jobs: [Job] = []

    static let maxLogLines = 400
    static let interruptedMessage = "Interrupted when GetVideo quit"

    private let tools: ToolManager
    private let jobsFile: URL
    private let legacyWorkDir: URL
    /// The loop that works through queued jobs; nil while there is nothing to do.
    private var runner: Task<Void, Never>?
    /// The job being processed and the Task running its pipeline (cancelling it stops the process).
    private var runningID: UUID?
    private var runningTask: Task<Void, Error>?
    private var stopped = false

    /// `legacyWorkDir` is where earlier versions kept temporary files; it is only ever emptied.
    init(tools: ToolManager, jobsFile: URL = AppPaths.jobsFile, legacyWorkDir: URL = AppPaths.work) {
        self.tools = tools
        self.jobsFile = jobsFile
        self.legacyWorkDir = legacyWorkDir
        let fm = FileManager.default

        if let data = try? Data(contentsOf: jobsFile), let saved = try? JSONDecoder().decode([Job].self, from: data) {
            jobs = saved
        }
        var changed = false
        for i in jobs.indices where [.downloading, .converting, .saving].contains(jobs[i].status) {
            Self.discardWork(for: jobs[i]) // what it left behind in its working folder
            jobs[i].status = .failed
            jobs[i].error = Self.interruptedMessage
            jobs[i].speed = ""
            jobs[i].eta = ""
            changed = true
        }
        if changed { persist() }

        try? fm.removeItem(at: legacyWorkDir)
        startRunner()
    }

    /// Queues one job per URL. Throws (with a message fit to show the user) if a URL or option is invalid.
    func add(urls: [String], settings: Settings) throws {
        let cleaned = urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw JobError(message: "Enter a video link first") }
        for url in cleaned where !(url.hasPrefix("http://") || url.hasPrefix("https://")) {
            throw JobError(message: "\"\(url)\" is not a link: it must start with http:// or https://")
        }
        _ = try Args.download(settings.download)
        _ = try Args.transcode(settings.transcode)
        for url in cleaned {
            jobs.append(Job(url: url, title: url, settings: settings))
        }
        persist()
        startRunner()
    }

    func cancel(_ id: UUID) {
        if id == runningID {
            runningTask?.cancel()   // Proc.run sends the process SIGINT; process() records the outcome
        } else {
            guard let i = index(id), jobs[i].status == .queued else { return }
            jobs[i].status = .canceled
            persist()
        }
    }

    /// Re-queues a failed or canceled job.
    func retry(_ id: UUID) {
        guard let i = index(id), jobs[i].status == .failed || jobs[i].status == .canceled else { return }
        jobs[i].status = .queued
        jobs[i].percent = 0
        jobs[i].speed = ""
        jobs[i].eta = ""
        jobs[i].error = nil
        jobs[i].log = []
        jobs[i].outputs = []
        persist()
        startRunner()
    }

    /// Removes a job that is not running.
    func remove(_ id: UUID) {
        guard id != runningID, let i = index(id) else { return }
        Self.deleteWork(for: jobs[i]) // a kept download goes with the job
        jobs.remove(at: i)
        persist()
    }

    func clearFinished() {
        let before = jobs.count
        for job in jobs where !job.status.isActive && job.id != runningID { Self.deleteWork(for: job) }
        jobs.removeAll { !$0.status.isActive && $0.id != runningID }
        if jobs.count != before { persist() }
    }

    /// Stops the running job's process; called when the app quits.
    func shutdown() {
        stopped = true
        // The app may be gone before the process has died, so the outcome is written down now.
        if let id = runningID, let i = index(id) {
            jobs[i].status = .failed
            jobs[i].error = Self.interruptedMessage
            jobs[i].speed = ""
            jobs[i].eta = ""
            persist()
        }
        runningTask?.cancel()
    }

    // MARK: Running

    private func index(_ id: UUID) -> Int? { jobs.firstIndex { $0.id == id } }

    private func startRunner() {
        guard runner == nil, !stopped, jobs.contains(where: { $0.status == .queued }) else { return }
        runner = Task { [weak self] in
            while let self, !self.stopped, let next = self.jobs.first(where: { $0.status == .queued }) {
                await self.process(next.id)
            }
            self?.runner = nil
        }
    }

    private func process(_ id: UUID) async {
        let outDir = Self.outputDir(index(id).map { jobs[$0].settings.output.dir } ?? "")
        let work = Self.workFolder(for: id, in: outDir)
        let task = Task { try await self.pipeline(id, work: work) }
        runningID = id
        runningTask = task
        let result = await task.result
        runningID = nil
        runningTask = nil
        if case .success = result {
            try? FileManager.default.removeItem(at: work)
        } else if let i = index(id) {
            Self.discardWork(for: jobs[i]) // keeps the download for "Try again" when the job asked for that
        }

        // After shutdown() the job is already recorded as interrupted; after remove-while-finishing
        // there is nothing to record.
        guard !stopped, let i = index(id) else { return }
        jobs[i].speed = ""
        jobs[i].eta = ""
        switch result {
        case .success:
            jobs[i].status = .done
            jobs[i].percent = 100
            jobs[i].error = nil
            jobs[i].downloads = []
        case .failure where task.isCancelled:
            jobs[i].status = .canceled
            jobs[i].error = nil
        case .failure(let error):
            jobs[i].status = .failed
            jobs[i].error = error.localizedDescription
        }
        persist()
    }

    /// Changes a job's stage and saves it.
    private func setStage(_ id: UUID, _ status: JobStatus, percent: Double) {
        guard let i = index(id) else { return }
        jobs[i].status = status
        jobs[i].percent = percent
        jobs[i].speed = ""
        jobs[i].eta = ""
        persist()
    }

    private func pipeline(_ id: UUID, work: URL) async throws {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let settings = job.settings
        let fm = FileManager.default

        let needed: [ToolName] = settings.converts ? [.ytdlp, .ffmpeg, .handbrake] : [.ytdlp, .ffmpeg]
        for name in needed where !ToolInstaller.isFile(tools.path(name)) {
            throw JobError(message: "\(name.rawValue) is not installed (see Tools)")
        }
        let outDir = Self.outputDir(settings.output.dir)
        do {
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            throw JobError(message: "Could not create the working folder: \(error.localizedDescription)")
        }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
        } catch {
            throw JobError(message: "Could not create temporary files in the working folder: \(error.localizedDescription)")
        }

        var files: [URL]
        if let kept = Self.keptDownloads(job) {
            files = kept
            note(id, "Using the download kept from last time; going straight to the conversion.")
        } else {
            files = try await download(id, url: job.url, options: settings.download, work: work)
            if files.isEmpty { throw JobError(message: "yt-dlp finished but reported no output file") }
            if Self.keepsDownload(settings), let i = index(id) {
                // Tracked in the job (and saved), so it survives a crash or a quit.
                jobs[i].downloads = files.map(\.path)
                persist()
            }
        }
        // yt-dlp reported the real title during the download.
        let title = jobs.first(where: { $0.id == id })?.title ?? job.title

        var outputs: [String] = []
        for src in files {
            var final = src
            if settings.converts {
                final = try await convert(id, source: src, options: settings.transcode, work: work)
            }
            try Task.checkCancellation()
            setStage(id, .saving, percent: 100)
            let name = Parsing.sanitize(Parsing.outputName(custom: settings.output.filename, title: title, url: job.url,
                                                           source: src, fileCount: files.count))
            let overwrite = settings.output.overwrite
            // Off the main actor: this is a copy when the output folder is on another volume.
            outputs += try await Task.detached { () -> [String] in
                var moved = [try Parsing.move(final, into: outDir, name: name, overwrite: overwrite).path]
                if settings.converts && settings.output.keepSource {
                    moved.append(try Parsing.move(src, into: outDir, name: name + " (source)", overwrite: overwrite).path)
                }
                return moved
            }.value
            // This file is finished: it is no longer waiting for a conversion.
            if let i = index(id) {
                jobs[i].downloads.removeAll { $0 == src.path }
                persist()
            }
        }
        if let i = index(id) { jobs[i].outputs = outputs }
    }

    /// True when a failed or canceled job leaves its downloaded file in the working folder, so
    /// "Try again" continues from the conversion instead of downloading again.
    static func keepsDownload(_ s: Settings) -> Bool { s.download.keepDownload && s.converts }

    /// The downloads a previous attempt left behind, or nil when there are none or any has gone,
    /// in which case the video is downloaded again.
    static func keptDownloads(_ job: Job) -> [URL]? {
        guard !job.downloads.isEmpty, ToolInstaller.isFile(URL(fileURLWithPath: job.downloads[0])),
              job.downloads.allSatisfy({ ToolInstaller.isFile(URL(fileURLWithPath: $0)) }) else { return nil }
        return job.downloads.map { URL(fileURLWithPath: $0) }
    }

    private static func work(for job: Job) -> URL { workFolder(for: job.id, in: outputDir(job.settings.output.dir)) }

    /// Empties a job's temporary folder. When the job keeps its download only HandBrake's
    /// half-written output goes; everything else stays so the job can continue.
    static func discardWork(for job: Job) {
        let fm = FileManager.default
        let work = work(for: job)
        guard keepsDownload(job.settings) else {
            try? fm.removeItem(at: work)
            return
        }
        for f in (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent.hasPrefix("out.") {
            try? fm.removeItem(at: f)
        }
        _ = rmdir(work.path) // only succeeds when nothing is left in it
    }

    /// Deletes a job's temporary folder with everything in it, kept download included.
    static func deleteWork(for job: Job) { try? FileManager.default.removeItem(at: work(for: job)) }

    /// Adds a line to a job's log.
    private func note(_ id: UUID, _ line: String) {
        guard let i = index(id) else { return }
        jobs[i].log.append(line)
    }

    /// A job's temporary folder: hidden, inside the working folder the video is saved to. yt-dlp
    /// downloads there and HandBrake converts there, so the finished file is moved with a rename on
    /// the same disk, and a big download never fills the system disk when the working folder is on
    /// a bigger drive.
    static func workFolder(for id: UUID, in outDir: URL) -> URL {
        outDir.appendingPathComponent(".getvideo-\(id.uuidString)", isDirectory: true)
    }

    /// "" means the Downloads folder; a leading `~` is the home folder.
    static func outputDir(_ dir: String) -> URL {
        let d = dir.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { return AppPaths.downloads }
        return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Runs yt-dlp and returns the files it reported.
    private func download(_ id: UUID, url: String, options: DownloadOptions, work: URL) async throws -> [URL] {
        var args = [
            "--ffmpeg-location", tools.path(.ffmpeg).path,
            "--no-colors", "--newline", "--progress",
            "--progress-template", "download:GVPROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "before_dl:GVTITLE %(title)s",
            "--print", "after_move:GVFILE %(filepath)s",
            "-P", work.path, "-o", "%(id)s.%(ext)s",
        ]
        args += try Args.download(options)
        args.append(url)

        setStage(id, .downloading, percent: 0)
        let feed = makeFeed(id)
        try await runStage("yt-dlp", tools.path(.ytdlp), args, feed) { line in
            if line.hasPrefix("GVPROG ") {
                guard let p = Parsing.ytdlpProgress(String(line.dropFirst(7))) else { return }
                feed.push {
                    if let pct = p.percent { $0.percent = pct }
                    $0.speed = p.speed
                    $0.eta = p.eta
                }
            } else if line.hasPrefix("GVTITLE ") {
                feed.push { $0.title = String(line.dropFirst(8)) }
            } else if line.hasPrefix("GVFILE ") {
                feed.addFile(String(line.dropFirst(7)))
            } else {
                feed.log(line)
            }
        }
        return feed.files.map { URL(fileURLWithPath: $0) }
    }

    /// Runs HandBrakeCLI on one file and returns the converted file (still in the work folder).
    private func convert(_ id: UUID, source: URL, options: TranscodeOptions, work: URL) async throws -> URL {
        var opts = try Args.transcode(options)
        var container = options.container
        if container.isEmpty {
            container = "mp4"
            opts = ["-f", "av_mp4"] + opts
        }
        let dst = work.appendingPathComponent("out." + container)
        try? FileManager.default.removeItem(at: dst)   // the previous file of a playlist has been moved, but be sure

        setStage(id, .converting, percent: 0)
        if options.trimMode != "" {
            var total = 0.0
            if Trim.needsScan(options) {
                let scan = await Proc.capture(tools.path(.handbrake), ["-i", source.path, "--scan"])
                guard let seconds = Trim.scanDuration(scan.output) else {
                    throw JobError(message: "HandBrakeCLI did not report the video's length, so it cannot be shortened")
                }
                total = seconds
            }
            if let cut = Trim.window(options, total: total) {
                opts += Trim.args(start: cut.start, length: cut.length)
                note(id, "Shortening to \(Trim.clockString(cut.length)), starting at \(Trim.clockString(cut.start)).")
            } else {
                note(id, "The video is already no longer than the length asked for; keeping all of it.")
            }
        }
        let feed = makeFeed(id)
        try await runStage("HandBrakeCLI", tools.path(.handbrake), ["-i", source.path, "-o", dst.path] + opts, feed) { line in
            if let p = Parsing.handBrakeProgress(line) {
                feed.push {
                    $0.percent = p.percent
                    $0.eta = p.eta ?? ""
                    if let fps = p.fps { $0.speed = fps + " fps" }
                }
            } else if !line.hasPrefix("Encoding:") {
                feed.log(line)
            }
        }
        // HandBrake can finish normally without writing anything, for instance when it does not
        // understand an option.
        let size = (try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0
        if size == 0 {
            throw JobError(message: "HandBrakeCLI finished without creating a video. Check the Convert settings, especially any extra arguments, and see the log.")
        }
        return dst
    }

    /// Runs one tool, then hands over whatever its feed still holds. A failure is reported as
    /// "<tool>: <its last ERROR line, or how it exited>".
    private func runStage(_ tool: String, _ exe: URL, _ args: [String], _ feed: StageFeed,
                          onLine: @escaping (String) -> Void) async throws {
        do {
            try await Proc.run(exe, args, onLine: onLine)
        } catch {
            apply(feed.close(), to: feed.jobID)
            if error is CancellationError { throw error }
            throw JobError(message: "\(tool): \(feed.lastError ?? error.localizedDescription)")
        }
        apply(feed.close(), to: feed.jobID)
    }

    private func makeFeed(_ id: UUID) -> StageFeed {
        StageFeed(jobID: id) { [weak self] batch in self?.apply(batch, to: id) }
    }

    /// Publishes a batch of process output on the job. Not persisted: these are progress ticks.
    private func apply(_ batch: StageFeed.Batch, to id: UUID) {
        guard !batch.isEmpty, !stopped, id == runningID, let i = index(id) else { return }
        var job = jobs[i]
        if let v = batch.percent { job.percent = v }
        if let v = batch.speed { job.speed = v }
        if let v = batch.eta { job.eta = v }
        if let v = batch.title, !v.isEmpty { job.title = v }
        if !batch.lines.isEmpty {
            job.log += batch.lines
            if job.log.count > Self.maxLogLines { job.log.removeFirst(job.log.count - Self.maxLogLines) }
        }
        jobs[i] = job   // one publish for the whole batch
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? FileManager.default.createDirectory(at: jobsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: jobsFile, options: .atomic)
    }
}

/// Collects one stage's process output on background threads and hands it to the main actor in
/// batches, at most about four a second. File paths and the last error line are kept here, read
/// directly, so none is lost to throttling.
final class StageFeed: @unchecked Sendable {
    struct Batch {
        var lines: [String] = []
        var percent: Double?
        var speed: String?
        var eta: String?
        var title: String?
        var isEmpty: Bool { lines.isEmpty && percent == nil && speed == nil && eta == nil && title == nil }
    }

    static let interval: TimeInterval = 0.25

    let jobID: UUID
    private let deliver: @MainActor (Batch) -> Void
    private let lock = NSLock()
    private var batch = Batch()
    private var scheduled = false
    private var closed = false
    private var lastDelivery = Date.distantPast
    private var _files: [String] = []
    private var _lastError: String?

    init(jobID: UUID, deliver: @escaping @MainActor (Batch) -> Void) {
        self.jobID = jobID
        self.deliver = deliver
    }

    /// Every path yt-dlp reported with GVFILE, in order.
    var files: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _files
    }

    /// The last output line containing "ERROR", without its "ERROR: " prefix.
    var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    func addFile(_ path: String) {
        lock.lock()
        _files.append(path)
        lock.unlock()
    }

    func log(_ line: String) {
        if line.contains("ERROR") {
            let text = line.hasPrefix("ERROR: ") ? String(line.dropFirst(7)) : line
            lock.lock()
            _lastError = text
            lock.unlock()
        }
        push { $0.lines.append(line) }
    }

    /// Adds to the pending batch and makes sure a delivery is on its way.
    func push(_ change: (inout Batch) -> Void) {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        change(&batch)
        let schedule = !scheduled
        scheduled = true
        let wait = max(0, Self.interval - Date().timeIntervalSince(lastDelivery))
        lock.unlock()
        guard schedule else { return }
        Task { @MainActor in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            self.deliver(self.take())
        }
    }

    private func take() -> Batch {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        lastDelivery = Date()
        let b = batch
        batch = Batch()
        return b
    }

    /// Ends the stage: returns what has not been delivered yet and ignores anything pushed later.
    func close() -> Batch {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        let b = batch
        batch = Batch()
        return b
    }
}
