import XCTest
@testable import GetVideo

/// Stand-ins for the three tools: yt-dlp writes a small file; HandBrake fails until a marker file
/// exists, then succeeds. Each call is counted so a test can tell whether yt-dlp ran again.
/// A port of resume_test.go.
@MainActor
final class ResumeTests: XCTestCase {
    /// Used by `EditFileTests`, which needs the same stand-in tools.
    func makeEditEnv(_ test: XCTestCase) throws -> (JobQueue, ResumeTests.Env) {
        let env = try makeEnv()
        test.addTeardownBlock { unsetenv("FAKE_CALLS") }
        return (env.queue(), env)
    }

    private static let fakeYtdlp = """
    #!/bin/sh
    dir=.
    while [ $# -gt 0 ]; do case "$1" in -P) dir="$2"; shift;; esac; shift; done
    echo x >> "$FAKE_CALLS.ytdlp"
    echo "GVTITLE Fake Video"
    printf video > "$dir/fake.mp4"
    echo "GVFILE $dir/fake.mp4"
    """

    private static let fakeHandbrake = """
    #!/bin/sh
    out=
    while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; esac; shift; done
    echo x >> "$FAKE_CALLS.hb"
    if [ -f "$FAKE_CALLS.nooutput" ]; then echo "usage: HandBrakeCLI ..." >&2; exit 0; fi
    if [ ! -f "$FAKE_CALLS.ok" ]; then printf partial > "$out"; echo "simulated crash" >&2; exit 3; fi
    printf converted > "$out"
    """

    struct Env {
        let dir: URL
        let folder: URL
        let calls: String
        let jobsFile: URL
        let tools: ToolManager
        @MainActor func queue() -> JobQueue {
            JobQueue(tools: tools, jobsFile: jobsFile, legacyWorkDir: dir.appendingPathComponent("legacy"))
        }
        func count(_ tool: String) -> Int { ((try? String(contentsOfFile: calls + "." + tool, encoding: .utf8)) ?? "").count / 2 }
        func touch(_ suffix: String) { FileManager.default.createFile(atPath: calls + "." + suffix, contents: nil) }
    }

    func makeEnv() throws -> Env {
        let dir = try makeTempDir(self)
        let bin = dir.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("yt-dlp", Self.fakeYtdlp), ("HandBrakeCLI", Self.fakeHandbrake), ("ffmpeg", "#!/bin/sh\n")] {
            let url = bin.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let calls = dir.appendingPathComponent("calls").path
        setenv("FAKE_CALLS", calls, 1)
        addTeardownBlock { unsetenv("FAKE_CALLS") }
        let folder = dir.appendingPathComponent("videos", isDirectory: true)
        return Env(dir: dir, folder: folder, calls: calls, jobsFile: dir.appendingPathComponent("jobs.json"),
                   tools: ToolManager(binDir: bin))
    }

    private func add(_ q: JobQueue, _ env: Env, keep: Bool) throws {
        var s = Settings()
        s.download.keepDownload = keep
        s.output.dir = env.folder.path
        try q.add(urls: ["https://example.com/v"], settings: s)
    }

    private func wait(_ q: JobQueue, for status: JobStatus) async throws -> Job {
        let start = Date()
        while Date().timeIntervalSince(start) < 10 {
            if q.jobs.count == 1, q.jobs[0].status == status { return q.jobs[0] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(status); jobs: \(q.jobs.map(\.status))")
        return q.jobs[0]
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// The reason for the setting: HandBrake crashes after a long download, and "Try again" must
    /// carry on from the conversion rather than downloading for hours again.
    func testFailedConversionResumesFromTheKeptDownload() async throws {
        let env = try makeEnv()
        let q = env.queue()
        try add(q, env, keep: true)
        let failed = try await wait(q, for: .failed)

        let work = JobQueue.workFolder(for: failed.id, in: env.folder)
        XCTAssertTrue(exists(work.appendingPathComponent("fake.mp4")), "the download was not kept")
        XCTAssertFalse(exists(work.appendingPathComponent("out.mp4")), "HandBrake's half-written file was left behind")
        XCTAssertEqual(failed.downloads.count, 1, "the download is not tracked")
        let saved = try String(contentsOf: env.jobsFile, encoding: .utf8)
        XCTAssertTrue(saved.contains("fake.mp4"), "the record is not saved, so it would not survive a quit")

        env.touch("ok") // HandBrake works now
        q.retry(failed.id)
        let done = try await wait(q, for: .done)

        XCTAssertEqual(env.count("ytdlp"), 1, "yt-dlp ran again; the kept download should have been used")
        XCTAssertEqual(env.count("hb"), 2)
        XCTAssertEqual(done.outputs.count, 1)
        XCTAssertEqual(try String(contentsOfFile: done.outputs[0], encoding: .utf8), "converted")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.folder.path).count, 1, "only the finished video should remain")
        XCTAssertTrue(done.downloads.isEmpty)
        XCTAssertTrue(done.log.contains { $0.contains("kept from last time") }, "the log should say the download was reused")
    }

    func testFailedConversionWithoutKeepingStartsOver() async throws {
        let env = try makeEnv()
        let q = env.queue()
        try add(q, env, keep: false)
        let failed = try await wait(q, for: .failed)
        XCTAssertFalse(exists(JobQueue.workFolder(for: failed.id, in: env.folder)), "the temporary folder was kept")
        XCTAssertTrue(failed.downloads.isEmpty)
        env.touch("ok")
        q.retry(failed.id)
        _ = try await wait(q, for: .done)
        XCTAssertEqual(env.count("ytdlp"), 2)
    }

    /// 2026-10-09: HandBrake exited normally without writing a video (it did not understand an
    /// option), and the job failed with a confusing "move ...: no such file or directory".
    func testHandbrakeWritingNothingGivesAClearError() async throws {
        let env = try makeEnv()
        env.touch("nooutput")
        let q = env.queue()
        try add(q, env, keep: true)
        let failed = try await wait(q, for: .failed)
        XCTAssertTrue(failed.error?.contains("finished without creating a video") == true, failed.error ?? "nil")
        XCTAssertEqual(failed.downloads.count, 1, "the download should still be kept")
    }

    func testRemovingAJobDeletesItsKeptDownload() async throws {
        let env = try makeEnv()
        let q = env.queue()
        try add(q, env, keep: true)
        let failed = try await wait(q, for: .failed)
        q.remove(failed.id)
        XCTAssertFalse(exists(JobQueue.workFolder(for: failed.id, in: env.folder)), "the kept download survived removing the job")
    }

    func testClearFinishedDeletesKeptDownloads() async throws {
        let env = try makeEnv()
        let q = env.queue()
        try add(q, env, keep: true)
        let failed = try await wait(q, for: .failed)
        q.clearFinished()
        XCTAssertTrue(q.jobs.isEmpty)
        XCTAssertFalse(exists(JobQueue.workFolder(for: failed.id, in: env.folder)))
    }

    /// If the app quits during a conversion, the next launch keeps the download for "Try again".
    func testInterruptedConversionKeepsTheDownload() throws {
        let env = try makeEnv()
        var s = Settings()
        s.output.dir = env.folder.path
        var job = Job(url: "https://example.com/v", title: "t", settings: s)
        job.status = .converting
        let work = JobQueue.workFolder(for: job.id, in: env.folder)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let kept = work.appendingPathComponent("fake.mp4")
        try Data("v".utf8).write(to: kept)
        try Data("half".utf8).write(to: work.appendingPathComponent("out.mp4"))
        job.downloads = [kept.path]
        try JSONEncoder().encode([job]).write(to: env.jobsFile)

        let q = env.queue()
        XCTAssertTrue(exists(kept), "the kept download was removed")
        XCTAssertFalse(exists(work.appendingPathComponent("out.mp4")), "half-written output was kept")
        XCTAssertEqual(q.jobs.first?.status, .failed)
        XCTAssertEqual(q.jobs.first?.downloads, [kept.path])
    }
}

/// A file already on disk is edited by HandBrake alone. Ports of the Go tests of the same names.
@MainActor
final class EditFileTests: XCTestCase {
    private func makeQueue() throws -> (JobQueue, ResumeTests.Env) {
        let helper = ResumeTests()
        return try helper.makeEditEnv(self)
    }

    private func wait(_ q: JobQueue, for status: JobStatus) async throws -> Job {
        let start = Date()
        while Date().timeIntervalSince(start) < 10 {
            if q.jobs.count == 1, q.jobs[0].status == status { return q.jobs[0] }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("timed out waiting for \(status); jobs: \(q.jobs.map(\.status))")
        return q.jobs[0]
    }

    func testEditingAFileOnDiskNeedsNoDownload() async throws {
        let (q, env) = try makeQueue()
        env.touch("ok")
        let src = env.dir.appendingPathComponent("My Lecture.mov")
        try Data("original".utf8).write(to: src)
        var s = Settings()
        s.output.dir = env.folder.path
        s.output.keepSource = true      // meaningless for a file: it is never copied
        s.transcode.skip = true         // converting is the whole point, so this is ignored
        try q.addFile(src.path, settings: s)
        let done = try await wait(q, for: .done)

        XCTAssertEqual(env.count("ytdlp"), 0)
        XCTAssertEqual(env.count("hb"), 1)
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "original", "the original was changed")
        XCTAssertEqual(done.outputs.map { ($0 as NSString).lastPathComponent }, ["My Lecture (edited).mp4"])
        XCTAssertEqual(try String(contentsOfFile: done.outputs[0], encoding: .utf8), "converted")
        XCTAssertEqual(done.title, "My Lecture.mov")
        XCTAssertEqual(done.url, "")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.folder.path).count, 1)
    }

    /// "Overwrite an existing file" must never overwrite the file being edited.
    func testEditingNeverOverwritesTheOriginal() async throws {
        let (q, env) = try makeQueue()
        env.touch("ok")
        try FileManager.default.createDirectory(at: env.folder, withIntermediateDirectories: true)
        let src = env.folder.appendingPathComponent("clip.mp4")
        try Data("original".utf8).write(to: src)
        var s = Settings()
        s.output.dir = env.folder.path
        s.output.filename = "clip"      // same folder, same name, same extension...
        s.output.overwrite = true       // ...with overwrite on: the worst case
        try q.addFile(src.path, settings: s)
        let done = try await wait(q, for: .done)
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "original", "the original was overwritten")
        XCTAssertEqual(done.outputs.map { ($0 as NSString).lastPathComponent }, ["clip (1).mp4"])
    }

    func testRejectsMissingFilesAndFolders() throws {
        let (q, env) = try makeQueue()
        XCTAssertThrowsError(try q.addFile(env.folder.appendingPathComponent("nope.mp4").path, settings: Settings()))
        XCTAssertThrowsError(try q.addFile(env.dir.path, settings: Settings()), "a folder is not a video")
        XCTAssertThrowsError(try q.addFile("  ", settings: Settings()))
        XCTAssertTrue(q.jobs.isEmpty)
    }

    /// If the file goes away before its turn, the job fails clearly.
    func testEditedFileThatDisappearsFailsClearly() async throws {
        let (_, env) = try makeQueue()
        var s = Settings()
        s.output.dir = env.folder.path
        var job = Job(url: "", title: "gone.mp4", settings: s)
        job.source = env.dir.appendingPathComponent("gone.mp4").path
        try JSONEncoder().encode([job]).write(to: env.jobsFile)
        let q = env.queue()      // the saved job is still queued, so it runs at once
        let failed = try await wait(q, for: .failed)
        XCTAssertTrue(failed.error?.contains("Cannot find the file") == true, failed.error ?? "nil")
    }
}
