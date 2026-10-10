import XCTest
@testable import GetVideo

@MainActor
final class JobQueueTests: XCTestCase {
    private struct Env {
        let dir: URL
        let tools: ToolManager
        var jobsFile: URL { dir.appendingPathComponent("jobs.json") }
        var work: URL { dir.appendingPathComponent("work", isDirectory: true) }
        @MainActor func queue() -> JobQueue { JobQueue(tools: tools, jobsFile: jobsFile, legacyWorkDir: work) }
    }

    /// A queue on temp folders with an empty tools folder, so every job that runs fails at once.
    private func makeEnv() throws -> Env {
        let dir = try makeTempDir(self)
        return Env(dir: dir, tools: ToolManager(binDir: dir.appendingPathComponent("bin", isDirectory: true)))
    }

    private func wait(_ seconds: TimeInterval = 5, until done: () -> Bool) async throws {
        let start = Date()
        while !done(), Date().timeIntervalSince(start) < seconds { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(done(), "timed out")
    }

    /// The working folder is where the video is saved AND where temporary files are kept
    /// (2026-10-09: before, they lived in the app's own data folder).
    func testTemporaryFolderIsInsideTheWorkingFolder() {
        let id = UUID()
        let folder = URL(fileURLWithPath: "/Volumes/Big/Videos", isDirectory: true)
        XCTAssertEqual(JobQueue.workFolder(for: id, in: folder).path, "/Volumes/Big/Videos/.getvideo-\(id.uuidString)")
    }

    /// A job interrupted by quitting must not leave its temporary folder in the user's folder, and
    /// must not touch the user's own files there.
    func testInterruptedJobsTemporaryFolderIsRemoved() throws {
        let env = try makeEnv()
        let folder = env.dir.appendingPathComponent("videos", isDirectory: true)
        var job = Job(url: "https://ok.example/v", title: "t", settings: Settings())
        job.settings.output.dir = folder.path
        job.status = .downloading
        let leftover = JobQueue.workFolder(for: job.id, in: folder)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let mine = folder.appendingPathComponent("My Video.mp4")
        try Data("x".utf8).write(to: mine)
        try JSONEncoder().encode([job]).write(to: env.jobsFile)

        let q = env.queue()
        XCTAssertEqual(q.jobs.first?.status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "temporary folder is left behind")
        XCTAssertTrue(FileManager.default.fileExists(atPath: mine.path), "a user file was removed")
    }

    func testAddValidates() throws {
        let q = try makeEnv().queue()
        XCTAssertThrowsError(try q.add(urls: ["https://ok.example/v", "ftp://bad.example/v"], settings: Settings())) { error in
            XCTAssertTrue(error.localizedDescription.contains("ftp://bad.example/v"), error.localizedDescription)
        }
        XCTAssertThrowsError(try q.add(urls: ["  "], settings: Settings()))
        var s = Settings()
        s.transcode.qualityMode = "bitrate"
        s.transcode.videoBitrate = 0
        XCTAssertThrowsError(try q.add(urls: ["https://ok.example/v"], settings: s))
        s = Settings()
        s.download.extraArgs = "\"open"
        XCTAssertThrowsError(try q.add(urls: ["https://ok.example/v"], settings: s))
        XCTAssertTrue(q.jobs.isEmpty, "nothing is queued when any part is invalid")
    }

    func testMissingToolsFailTheJobAndRetryRequeues() async throws {
        let env = try makeEnv()
        let q = env.queue()
        try q.add(urls: [" https://a.example/1 ", "https://a.example/2"], settings: Settings())
        XCTAssertEqual(q.jobs.map(\.url), ["https://a.example/1", "https://a.example/2"])
        XCTAssertEqual(q.jobs.map(\.title), q.jobs.map(\.url))
        try await wait { q.jobs.allSatisfy { $0.status == .failed } }
        XCTAssertEqual(q.jobs[0].error, "yt-dlp is not installed (see Tools)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.work.path), "the app's own work folder is no longer used")

        // Saved on every status change.
        let saved = try JSONDecoder().decode([Job].self, from: Data(contentsOf: env.jobsFile))
        XCTAssertEqual(saved.map(\.status), [.failed, .failed])

        let id = q.jobs[0].id
        q.retry(id)
        XCTAssertNil(q.jobs[0].error)
        try await wait { q.jobs[0].status == .failed && q.jobs[0].error != nil }

        q.remove(id)
        XCTAssertEqual(q.jobs.count, 1)
        q.clearFinished()
        XCTAssertTrue(q.jobs.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode([Job].self, from: Data(contentsOf: env.jobsFile)).count, 0)
    }

    func testLoadMarksInterruptedJobsAndCleansWorkDir() async throws {
        let env = try makeEnv()
        var a = Job(url: "https://a.example/1", title: "One", settings: Settings())
        a.status = .converting
        a.percent = 40
        var b = Job(url: "https://a.example/2", title: "Two", settings: Settings())
        b.status = .done
        var c = Job(url: "https://a.example/3", title: "Three", settings: Settings())
        c.status = .canceled
        try JSONEncoder().encode([a, b, c]).write(to: env.jobsFile)
        let stale = env.work.appendingPathComponent("old-job", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        let q = env.queue()
        XCTAssertEqual(q.jobs.map(\.status), [.failed, .done, .canceled])
        XCTAssertEqual(q.jobs[0].error, "Interrupted when GetVideo quit")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))

        q.clearFinished()
        XCTAssertTrue(q.jobs.isEmpty)
    }

    func testCancelQueuedJobAndResumeOnLoad() async throws {
        let env = try makeEnv()
        var a = Job(url: "https://a.example/1", title: "One", settings: Settings())
        a.status = .queued
        try JSONEncoder().encode([a]).write(to: env.jobsFile)
        let q = env.queue()
        // Nothing has run yet: the runner starts on the next main-actor turn.
        XCTAssertEqual(q.jobs[0].status, .queued)
        q.cancel(a.id)
        XCTAssertEqual(q.jobs[0].status, .canceled)
        XCTAssertNil(q.jobs[0].error)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(q.jobs[0].status, .canceled, "a canceled job is not picked up")

        // A queued job in the file resumes by itself (and here fails: no tools).
        a.status = .queued
        try JSONEncoder().encode([a]).write(to: env.jobsFile)
        let q2 = env.queue()
        try await wait { q2.jobs[0].status == .failed }
    }

    func testStageFeedThrottlesAndKeepsEverything() async throws {
        var batches: [StageFeed.Batch] = []
        let feed = StageFeed(jobID: UUID()) { batches.append($0) }
        await Task.detached {
            for i in 0..<500 {
                feed.push { $0.percent = Double(i) }
                feed.log(i == 250 ? "ERROR: [youtube] abc: Video unavailable" : "line \(i)")
                feed.addFile("/w/\(i).mp4")
            }
        }.value
        try await Task.sleep(nanoseconds: 400_000_000)
        let rest = feed.close()
        feed.log("after close")
        XCTAssertLessThanOrEqual(batches.count, 4, "500 lines must not mean 500 publishes")
        let lines = batches.flatMap(\.lines) + rest.lines
        XCTAssertEqual(lines.count, 500)
        XCTAssertEqual(lines.last, "line 499")
        XCTAssertEqual((batches.last { $0.percent != nil })?.percent ?? rest.percent, 499)
        XCTAssertEqual(feed.files.count, 500)
        XCTAssertEqual(feed.lastError, "[youtube] abc: Video unavailable")
    }
}

/// The real thing, off by default: `GETVIDEO_E2E=1 swift test --filter EndToEndTests`.
/// Needs the network and installed tools (GETVIDEO_E2E_BIN, or the app's own bin folder).
@MainActor
final class EndToEndTests: XCTestCase {
    func testDownloadConvertSave() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["GETVIDEO_E2E"] == "1", "set GETVIDEO_E2E=1 to run")
        let bin = env["GETVIDEO_E2E_BIN"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.bin
        let dir = try makeTempDir(self)
        let out = dir.appendingPathComponent("out", isDirectory: true)

        let tools = ToolManager(binDir: bin)
        await tools.refresh(checkLatest: false)
        XCTAssertTrue(tools.ready, "tools missing in \(bin.path)")
        XCTAssertTrue(tools.presets.contains { $0.presets.contains("Fast 480p30") }, "preset list: \(tools.presets.map(\.category))")

        let queue = JobQueue(tools: tools, jobsFile: dir.appendingPathComponent("jobs.json"),
                             legacyWorkDir: dir.appendingPathComponent("work", isDirectory: true))
        var s = Settings()
        s.download.maxHeight = 360
        s.transcode.preset = "Fast 480p30"
        s.transcode.trimMode = "percent"   // keep the last half of the 19-second clip
        s.transcode.trimPercent = 50
        s.transcode.trimKeep = "last"
        s.output.dir = out.path
        try queue.add(urls: ["https://www.youtube.com/watch?v=jNQXAC9IVRw"], settings: s)

        var seen: [JobStatus] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 180 {
            let st = queue.jobs[0].status
            if seen.last != st { seen.append(st) }
            if !st.isActive { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let job = queue.jobs[0]
        print("E2E stages: \(seen.map(\.rawValue)) title: \(job.title) outputs: \(job.outputs) error: \(job.error ?? "-")")
        if job.status != .done { print(job.log.suffix(30).joined(separator: "\n")) }
        XCTAssertEqual(job.status, .done, job.error ?? "")
        XCTAssertEqual(job.percent, 100)
        XCTAssertEqual(job.outputs.count, 1)
        let file = try XCTUnwrap(job.outputs.first)
        XCTAssertTrue(file.hasPrefix(out.path) && file.hasSuffix(".mp4"), file)
        let size = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(size, 10_000)
        XCTAssertTrue(job.log.contains { $0.hasPrefix("Shortening to 0:00:10") }, "the cut was not applied: \(job.log.suffix(8))")
        XCTAssertNotEqual(job.title, job.url, "yt-dlp reports the title")
        let left = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(left.count, 1, "only the finished video remains in the working folder: \(left)")
        XCTAssertTrue(seen.contains(.downloading) && seen.contains(.converting), "\(seen)")
    }

    /// A local file, edited by the real HandBrake: shortened to 6 seconds, original untouched.
    func testEndToEndEditsALocalFile() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["GETVIDEO_E2E"] == "1", "set GETVIDEO_E2E=1 to run")
        let bin = env["GETVIDEO_E2E_BIN"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? AppPaths.bin
        let input = try XCTUnwrap(env["GETVIDEO_E2E_FILE"], "set GETVIDEO_E2E_FILE to a short video")
        let dir = try makeTempDir(self)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let before = try Data(contentsOf: URL(fileURLWithPath: input))

        let tools = ToolManager(binDir: bin)
        await tools.refresh(checkLatest: false)
        let queue = JobQueue(tools: tools, jobsFile: dir.appendingPathComponent("jobs.json"),
                             legacyWorkDir: dir.appendingPathComponent("work", isDirectory: true))
        var s = Settings()
        s.transcode.preset = "Fast 480p30"
        s.transcode.trimMode = "duration"
        s.transcode.trimLength = "0:06"
        s.output.dir = out.path
        try queue.addFile(input, settings: s)

        let start = Date()
        while Date().timeIntervalSince(start) < 120, queue.jobs[0].status.isActive { try await Task.sleep(nanoseconds: 100_000_000) }
        let job = queue.jobs[0]
        XCTAssertEqual(job.status, .done, job.error ?? job.log.suffix(10).joined(separator: "\n"))
        XCTAssertTrue(job.log.contains { $0.hasPrefix("Shortening to 0:00:06") }, "\(job.log.suffix(8))")
        let file = try XCTUnwrap(job.outputs.first)
        XCTAssertTrue(file.hasSuffix("(edited).mp4"), file)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: input)), before, "the original was changed")
    }
}
