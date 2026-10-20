import CryptoKit
import XCTest
@testable import GetVideo

@MainActor
final class AppUpdaterTests: XCTestCase {
    // MARK: Helpers

    /// A tiny signed app bundle: enough for the updater's checks (identity, version, signature).
    @discardableResult
    private func makeApp(at url: URL, version: String, id: String = AppUpdater.bundleIdentifier,
                         minimumOS: String = "14.0", marker: String = "new") throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleVersion": version,
                                    "CFBundleExecutable": "GetVideo", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": minimumOS]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        let exe = url.appendingPathComponent("Contents/MacOS/GetVideo")
        try Data("#!/bin/sh\n# \(marker)\n".utf8).write(to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--deep", "--sign", "-", url.path]
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "could not sign the test app")
        return url
    }

    private func zip(_ app: URL, to zip: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
    }

    private func sha(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    /// A zip of a fresh app at `version`, and its checksum.
    private func release(in dir: URL, version: String, id: String = AppUpdater.bundleIdentifier, minimumOS: String = "14.0") throws -> (zip: URL, sha: String) {
        let app = try makeApp(at: dir.appendingPathComponent("src-\(UUID().uuidString)/GetVideo.app"), version: version, id: id, minimumOS: minimumOS)
        let z = dir.appendingPathComponent("zip-\(UUID().uuidString).zip")
        try zip(app, to: z)
        return (z, try sha(z))
    }

    private func throwsUpdateError(_ body: () async throws -> Void, contains text: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("expected an error containing \"\(text)\"", file: file, line: line)
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(text), "\(error.localizedDescription)", file: file, line: line)
        }
    }

    // MARK: Versions and releases

    func testIsNewer() {
        XCTAssertTrue(AppUpdater.isNewer("0.7.1", than: "0.7.0"))
        XCTAssertTrue(AppUpdater.isNewer("v0.8.0", than: "0.7.9"))
        XCTAssertTrue(AppUpdater.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(AppUpdater.isNewer("0.10.0", than: "0.9.0"), "numbers, not text: 10 is more than 9")
        XCTAssertFalse(AppUpdater.isNewer("0.7.0", than: "0.7.0"))
        XCTAssertFalse(AppUpdater.isNewer("0.7.0", than: "0.7.1"))
        XCTAssertFalse(AppUpdater.isNewer("0.7.0-3-gabc123", than: "0.7.0"), "a suffix is ignored")
    }

    func testParsingGitHubsAnswer() throws {
        let json = #"{"tag_name":"v0.8.0","assets":[{"name":"SHA256SUMS","browser_download_url":"https://x.example/SHA256SUMS"},{"name":"GetVideo-mac-native.zip","browser_download_url":"https://x.example/GetVideo-mac-native.zip"},{"name":"other.zip","browser_download_url":"https://x.example/other.zip"}]}"#
        let r = try AppUpdater.release(from: Data(json.utf8))
        XCTAssertEqual(r.version, "0.8.0")
        XCTAssertEqual(r.zipURL.absoluteString, "https://x.example/GetVideo-mac-native.zip")
        XCTAssertEqual(r.sumsURL?.absoluteString, "https://x.example/SHA256SUMS")
        XCTAssertThrowsError(try AppUpdater.release(from: Data(#"{"tag_name":"v1","assets":[]}"#.utf8)))
    }

    func testCheck() async {
        let zip = URL(string: "https://x.example/z.zip")!
        let newer = AppUpdater(currentVersion: "0.7.0", fetchRelease: { AppRelease(version: "0.8.0", zipURL: zip, sumsURL: nil) })
        await newer.check()
        XCTAssertEqual(newer.state, .available("0.8.0"))
        XCTAssertEqual(newer.latestVersion, "0.8.0")
        XCTAssertNotNil(newer.lastChecked)

        let same = AppUpdater(currentVersion: "0.8.0", fetchRelease: { AppRelease(version: "0.8.0", zipURL: zip, sumsURL: nil) })
        await same.check()
        XCTAssertEqual(same.state, .upToDate)

        struct Offline: Error {}
        let loud = AppUpdater(currentVersion: "0.7.0", fetchRelease: { throw URLError(.notConnectedToInternet) })
        await loud.check()
        guard case .failed(let message) = loud.state else { return XCTFail("\(loud.state)") }
        XCTAssertTrue(message.contains("No internet connection"), message)
        XCTAssertNil(loud.lastChecked)

        let quiet = AppUpdater(currentVersion: "0.7.0", fetchRelease: { throw Offline() })
        await quiet.check(silent: true)
        XCTAssertEqual(quiet.state, .idle, "the check at launch does not complain")
    }

    // MARK: Staging

    func testStageAcceptsAGoodRelease() async throws {
        let dir = try makeTempDir(self)
        let r = try release(in: dir, version: "0.8.0")
        let app = try await AppUpdater.stage(zip: r.zip, expectedSHA256: r.sha, into: dir.appendingPathComponent("stage"), currentVersion: "0.7.0")
        XCTAssertEqual(app.lastPathComponent, "GetVideo.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
    }

    func testStageRefusesWhatItCannotTrust() async throws {
        let dir = try makeTempDir(self)
        func stage(_ r: (zip: URL, sha: String), sha: String? = nil, current: String = "0.7.0") async throws {
            _ = try await AppUpdater.stage(zip: r.zip, expectedSHA256: sha ?? r.sha, into: dir.appendingPathComponent("s-\(UUID().uuidString)"), currentVersion: current)
        }
        let good = try release(in: dir, version: "0.8.0")
        await throwsUpdateError({ try await stage(good, sha: String(repeating: "0", count: 64)) }, contains: "checksum does not match")
        await throwsUpdateError({ try await stage(good, current: "0.8.0") }, contains: "not newer")
        await throwsUpdateError({ try await stage(try self.release(in: dir, version: "0.9.0", id: "com.example.other")) }, contains: "not GetVideo")
        await throwsUpdateError({ try await stage(try self.release(in: dir, version: "0.9.0", minimumOS: "99.0")) }, contains: "needs macOS 99.0")

        // An app changed after it was signed.
        let tampered = try makeApp(at: dir.appendingPathComponent("t/GetVideo.app"), version: "0.9.0")
        try Data("#!/bin/sh\n# evil\n".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/GetVideo"))
        let tz = dir.appendingPathComponent("tampered.zip")
        try zip(tampered, to: tz)
        await throwsUpdateError({ try await stage((tz, try self.sha(tz))) }, contains: "signature does not verify")

        // A zip with no GetVideo.app in it.
        let other = try makeApp(at: dir.appendingPathComponent("o/Other.app"), version: "0.9.0")
        let oz = dir.appendingPathComponent("other.zip")
        try zip(other, to: oz)
        await throwsUpdateError({ try await stage((oz, try self.sha(oz))) }, contains: "does not contain GetVideo.app")
    }

    // MARK: The swap script

    private func runScript(old: URL, new: URL, stage: URL) throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("getvideo-relaunch-\(UUID().uuidString).sh")
        addTeardownBlock { try? FileManager.default.removeItem(at: script) }
        try AppUpdater.relaunchScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, "99999999", new.path, old.path, stage.path]   // no such process: nothing to wait for
        p.environment = ["GETVIDEO_NO_OPEN": "1", "PATH": "/usr/bin:/bin"]
        try p.run()
        p.waitUntilExit()
    }

    private func marker(_ app: URL) -> String? {
        (try? String(contentsOf: app.appendingPathComponent("Contents/MacOS/GetVideo"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "# ").last
    }

    func testTheScriptSwapsTheAppAndTidiesUp() throws {
        let dir = try makeTempDir(self)
        let old = try makeApp(at: dir.appendingPathComponent("Apps/GetVideo.app"), version: "0.7.0", marker: "old")
        let stage = dir.appendingPathComponent("Apps/.stage", isDirectory: true)
        let new = try makeApp(at: stage.appendingPathComponent("GetVideo.app"), version: "0.8.0", marker: "new")
        try runScript(old: old, new: new, stage: stage)

        XCTAssertEqual(marker(old), "new", "the new app is in place")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Apps").path), ["GetVideo.app"],
                       "no backup and no staging folder are left behind")
    }

    /// If the new app cannot be moved in, the old one must be back where it was.
    func testTheScriptPutsTheOldAppBackWhenTheSwapFails() throws {
        let dir = try makeTempDir(self)
        let old = try makeApp(at: dir.appendingPathComponent("Apps/GetVideo.app"), version: "0.7.0", marker: "old")
        let stage = dir.appendingPathComponent("Apps/.stage", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try runScript(old: old, new: stage.appendingPathComponent("Missing.app"), stage: stage)

        XCTAssertEqual(marker(old), "old", "the old app was lost")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Apps").path), ["GetVideo.app"])
    }

    // MARK: The whole install

    private final class Recorder: @unchecked Sendable {
        var launched: [(script: URL, args: [String])] = []
        var quit = 0
    }

    private func updater(dir: URL, current: String = "0.7.0", zip: URL, sums: String?, sumsAvailable: Bool = true,
                         bundle: URL, rec: Recorder) -> AppUpdater {
        let sumsFile = dir.appendingPathComponent("SHA256SUMS")
        if let sums { try? Data(sums.utf8).write(to: sumsFile) }
        let release = AppRelease(version: "0.8.0", zipURL: URL(string: "https://x.example/GetVideo-mac-native.zip")!,
                                 sumsURL: sumsAvailable ? URL(string: "https://x.example/SHA256SUMS") : nil)
        return AppUpdater(currentVersion: current, bundleURL: bundle,
                          fetchRelease: { release },
                          download: { url, dst in
                              let src = url.lastPathComponent == "SHA256SUMS" ? sumsFile : zip
                              try? FileManager.default.removeItem(at: dst)
                              try FileManager.default.copyItem(at: src, to: dst)
                          },
                          launch: { script, args in rec.launched.append((script, args)) },
                          quit: { rec.quit += 1 })
    }

    func testInstallAndRestart() async throws {
        let dir = try makeTempDir(self)
        let bundle = try makeApp(at: dir.appendingPathComponent("Applications/GetVideo.app"), version: "0.7.0", marker: "old")
        let r = try release(in: dir, version: "0.8.0")
        let rec = Recorder()
        let u = updater(dir: dir, zip: r.zip, sums: "\(r.sha)  GetVideo-mac-native.zip\n", bundle: bundle, rec: rec)

        await u.check()
        XCTAssertEqual(u.state, .available("0.8.0"))
        await u.installAndRestart()

        XCTAssertEqual(u.state, .installing, "waiting for the app to quit")
        XCTAssertEqual(rec.quit, 1)
        let launch = try XCTUnwrap(rec.launched.first)
        XCTAssertEqual(launch.args.count, 4)
        XCTAssertEqual(launch.args[0], String(ProcessInfo.processInfo.processIdentifier))
        XCTAssertEqual(launch.args[2], bundle.path)
        XCTAssertTrue(launch.args[1].hasPrefix(bundle.deletingLastPathComponent().path), "staged beside the app, so the swap is a rename")
        XCTAssertEqual(marker(URL(fileURLWithPath: launch.args[1])), "new")
        XCTAssertEqual(marker(bundle), "old", "the running app is untouched until it has quit")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: launch.script.path))
    }

    func testInstallRefusesWhenItCannotBeSafe() async throws {
        let dir = try makeTempDir(self)
        let bundle = try makeApp(at: dir.appendingPathComponent("Applications/GetVideo.app"), version: "0.7.0", marker: "old")
        let r = try release(in: dir, version: "0.8.0")

        // A bad checksum: nothing is installed and the app does not quit.
        var rec = Recorder()
        var u = updater(dir: dir, zip: r.zip, sums: String(repeating: "0", count: 64) + "  GetVideo-mac-native.zip\n", bundle: bundle, rec: rec)
        await u.check()
        await u.installAndRestart()
        guard case .failed(let m1) = u.state else { return XCTFail("\(u.state)") }
        XCTAssertTrue(m1.contains("checksum does not match"), m1)
        XCTAssertEqual(rec.quit, 0)
        XCTAssertTrue(rec.launched.isEmpty)

        // A release without a checksum file.
        rec = Recorder()
        u = updater(dir: dir, zip: r.zip, sums: nil, sumsAvailable: false, bundle: bundle, rec: rec)
        await u.check()
        await u.installAndRestart()
        guard case .failed(let m2) = u.state else { return XCTFail("\(u.state)") }
        XCTAssertTrue(m2.contains("no checksum file"), m2)
        XCTAssertEqual(rec.quit, 0)

        // Running from a translocated (read-only, randomised) path.
        rec = Recorder()
        let moved = dir.appendingPathComponent("AppTranslocation/ABC/d/GetVideo.app")
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        u = updater(dir: dir, zip: r.zip, sums: "\(r.sha)  GetVideo-mac-native.zip\n", bundle: moved, rec: rec)
        await u.check()
        await u.installAndRestart()
        guard case .failed(let m3) = u.state else { return XCTFail("\(u.state)") }
        XCTAssertTrue(m3.contains("Applications folder"), m3)
        XCTAssertEqual(rec.quit, 0)

        // After a failure the button can be pressed again.
        u.dismissFailure()
        XCTAssertEqual(u.state, .available("0.8.0"))
    }
}
