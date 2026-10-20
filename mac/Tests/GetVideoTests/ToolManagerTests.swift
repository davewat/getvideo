import XCTest
@testable import GetVideo

/// "Check for Updates": look up the newest versions, show them next to what is installed, update.
@MainActor
final class ToolManagerTests: XCTestCase {
    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [ToolName] = []
        func add(_ n: ToolName) { lock.lock(); names.append(n); lock.unlock() }
        var all: [ToolName] { lock.lock(); defer { lock.unlock() }; return names }
    }

    /// A bin folder with all three tools installed at the given versions.
    private func install(_ versions: [ToolName: String], into bin: URL) throws {
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, v) in versions {
            try Data("x".utf8).write(to: bin.appendingPathComponent(name.rawValue))
            try Data((v + "\n").utf8).write(to: bin.appendingPathComponent(name.rawValue + ".version"))
        }
    }

    private func tool(_ m: ToolManager, _ n: ToolName) -> Tool { m.tools.first { $0.name == n }! }

    func testCheckShowsNewestNextToInstalled() async throws {
        let bin = try makeTempDir(self).appendingPathComponent("bin")
        try install([.ytdlp: "1", .handbrake: "2", .ffmpeg: "3"], into: bin)
        let latest: [ToolName: String] = [.ytdlp: "1", .handbrake: "5", .ffmpeg: "6"]
        let m = ToolManager(binDir: bin, lookupLatest: { latest[$0]! })

        XCTAssertNil(m.lastChecked)
        XCTAssertEqual(tool(m, .handbrake).latest, "", "nothing is known before the first check")
        await m.checkForUpdates()

        XCTAssertFalse(m.checking)
        XCTAssertNotNil(m.lastChecked)
        XCTAssertEqual(tool(m, .handbrake).version, "2")
        XCTAssertEqual(tool(m, .handbrake).latest, "5")
        XCTAssertTrue(tool(m, .handbrake).updateAvailable)
        XCTAssertFalse(tool(m, .ytdlp).updateAvailable, "same version: up to date")
        XCTAssertEqual(m.updatesAvailable, 2)
    }

    /// One failed lookup must be reported for that tool, without hiding the others.
    func testAFailedLookupIsReportedPerTool() async throws {
        let bin = try makeTempDir(self).appendingPathComponent("bin")
        try install([.ytdlp: "1", .handbrake: "2", .ffmpeg: "3"], into: bin)
        let m = ToolManager(binDir: bin, lookupLatest: { name in
            if name == .handbrake { throw ToolError(message: "GitHub answered 403 for the latest HandBrake/HandBrake release") }
            return "9"
        })
        await m.checkForUpdates()
        XCTAssertEqual(tool(m, .ytdlp).latest, "9")
        XCTAssertNil(tool(m, .ytdlp).checkError)
        XCTAssertEqual(tool(m, .handbrake).latest, "")
        XCTAssertEqual(tool(m, .handbrake).checkError, "GitHub is limiting requests right now. Try again in a few minutes.")
        XCTAssertNotNil(m.lastChecked, "two lookups worked")
    }

    func testEveryLookupFailingIsNotACheck() async throws {
        let bin = try makeTempDir(self).appendingPathComponent("bin")
        try install([.ytdlp: "1", .handbrake: "2", .ffmpeg: "3"], into: bin)
        let m = ToolManager(binDir: bin, lookupLatest: { _ in throw URLError(.notConnectedToInternet) })
        await m.checkForUpdates()
        XCTAssertNil(m.lastChecked)
        XCTAssertEqual(m.tools.map(\.checkError), Array(repeating: "No internet connection.", count: 3))
        XCTAssertEqual(m.updatesAvailable, 0)
        // Coming back online clears the errors.
        let online = ToolManager(binDir: bin, lookupLatest: { _ in "1" })
        await online.checkForUpdates()
        XCTAssertTrue(online.tools.allSatisfy { $0.checkError == nil })
    }

    func testUpdateAllInstallsOnlyWhatIsOutdated() async throws {
        let bin = try makeTempDir(self).appendingPathComponent("bin")
        try install([.ytdlp: "1", .handbrake: "2", .ffmpeg: "3"], into: bin)
        let latest: [ToolName: String] = [.ytdlp: "1", .handbrake: "5", .ffmpeg: "6"]
        let calls = Calls()
        let m = ToolManager(binDir: bin, lookupLatest: { latest[$0]! }, performInstall: { name in
            calls.add(name)
            let v = latest[name]!
            try Data((v + "\n").utf8).write(to: bin.appendingPathComponent(name.rawValue + ".version"))
            return v
        })
        await m.checkForUpdates()
        await m.updateAll()

        XCTAssertEqual(Set(calls.all), [.handbrake, .ffmpeg], "yt-dlp was already current")
        XCTAssertEqual(m.updatesAvailable, 0)
        XCTAssertEqual(tool(m, .handbrake).version, "5")
        XCTAssertEqual(tool(m, .ffmpeg).version, "6")
        XCTAssertNil(tool(m, .handbrake).error)
    }
}
