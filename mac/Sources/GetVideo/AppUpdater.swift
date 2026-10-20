import AppKit
import CryptoKit
import Foundation

/// The newest published version of the app and where to get it.
struct AppRelease: Equatable, Sendable {
    let version: String
    let zipURL: URL
    let sumsURL: URL?
}

/// Lets the app update itself: looks for a newer release on GitHub, downloads and checks it, swaps
/// it in for the running app and starts it again.
///
/// The swap is done by a small script that waits for this process to quit, because an app cannot
/// replace itself while it is running. The new copy is staged inside the folder the app lives in,
/// so the swap is a rename on the same disk, and the old copy is put back if anything goes wrong.
@MainActor
final class AppUpdater: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading
        case installing
        case failed(String)
    }

    nonisolated static let bundleIdentifier = "com.davewat.getvideo"
    nonisolated static let zipName = "GetVideo-mac-native.zip"
    nonisolated static let sumsName = "SHA256SUMS"

    @Published private(set) var state: State = .idle
    /// When the newest version was last looked up successfully.
    @Published private(set) var lastChecked: Date?
    /// The newest version seen, or "" before the first successful check.
    @Published private(set) var latestVersion = ""

    let currentVersion: String
    private let bundleURL: URL
    private let fetchRelease: @Sendable () async throws -> AppRelease
    private let download: @Sendable (URL, URL) async throws -> Void
    private let launch: @MainActor (_ script: URL, _ arguments: [String]) throws -> Void
    private let quit: @MainActor () -> Void
    private var release: AppRelease?

    init(currentVersion: String = AppUpdater.bundleVersion,
         bundleURL: URL = Bundle.main.bundleURL,
         fetchRelease: (@Sendable () async throws -> AppRelease)? = nil,
         download: (@Sendable (URL, URL) async throws -> Void)? = nil,
         launch: (@MainActor (URL, [String]) throws -> Void)? = nil,
         quit: (@MainActor () -> Void)? = nil) {
        self.currentVersion = currentVersion
        self.bundleURL = bundleURL
        self.fetchRelease = fetchRelease ?? { try await Self.latestRelease() }
        self.download = download ?? { try await Self.downloadFile(from: $0, to: $1) }
        self.launch = launch ?? { script, arguments in
            // `nohup ... &` in a shell of its own, so the script outlives this app.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "nohup /bin/sh \"$0\" \"$@\" >/dev/null 2>&1 &", script.path] + arguments
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
        }
        self.quit = quit ?? { NSApp.terminate(nil) }
    }

    nonisolated static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    var updateAvailable: Bool { if case .available = state { return true } else { return false } }

    /// True while a check, download or install is running.
    var busy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    // MARK: Checking

    /// Looks for a newer version. `silent` is for the check at launch: a failure there is not worth
    /// telling anyone about.
    func check(silent: Bool = false) async {
        guard !busy else { return }
        state = .checking
        do {
            let found = try await fetchRelease()
            release = found
            latestVersion = found.version
            lastChecked = Date()
            state = Self.isNewer(found.version, than: currentVersion) ? .available(found.version) : .upToDate
        } catch {
            state = silent ? .idle : .failed("Could not check for a new version of GetVideo. \(ToolManager.checkMessage(error))")
        }
    }

    // MARK: Installing

    /// Downloads the new version, swaps it in for this app and starts it. This app quits.
    func installAndRestart() async {
        guard case .available = state, let release else { return }
        do {
            try Self.preflight(bundleURL: bundleURL)
            guard let sumsURL = release.sumsURL else {
                throw UpdateError("This release has no checksum file, so it cannot be verified. Download it from the website instead.")
            }
            let parent = bundleURL.deletingLastPathComponent()
            let stage = parent.appendingPathComponent(".GetVideo-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)

            state = .downloading
            let zip = stage.appendingPathComponent(Self.zipName)
            let sums = stage.appendingPathComponent(Self.sumsName)
            try await download(sumsURL, sums)
            try await download(release.zipURL, zip)
            guard let expected = Parsing.checksum(in: (try? String(contentsOf: sums, encoding: .utf8)) ?? "", asset: Self.zipName) else {
                throw UpdateError("The checksum file does not list \(Self.zipName).")
            }

            state = .installing
            let app = try await Self.stage(zip: zip, expectedSHA256: expected, into: stage, currentVersion: currentVersion)

            let script = stage.appendingPathComponent("relaunch.sh")
            try Self.relaunchScript.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            try launch(script, [String(ProcessInfo.processInfo.processIdentifier), app.path, bundleURL.path, stage.path])
            quit()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Puts a failed state back to "available" so the button can be pressed again.
    func dismissFailure() {
        if case .failed = state { state = release.map { Self.isNewer($0.version, than: currentVersion) ? .available($0.version) : .upToDate } ?? .idle }
    }

    // MARK: Pieces (static, so tests can use them directly)

    struct UpdateError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// "v0.7.1" is newer than "0.7.0"; compares the numbers, ignoring a leading v and any suffix.
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            let core = s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// Whether this copy of the app can replace itself where it is.
    static func preflight(bundleURL: URL) throws {
        guard bundleURL.pathExtension == "app" else {
            throw UpdateError("GetVideo is not running as an app, so it cannot update itself.")
        }
        if bundleURL.path.contains("/AppTranslocation/") {
            throw UpdateError("Move GetVideo to your Applications folder and open it from there, then update.")
        }
        let parent = bundleURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError("GetVideo cannot replace itself in \(parent.path). Download the new version from the website instead.")
        }
    }

    /// Checks the downloaded zip and unpacks it; returns the new app, ready to be swapped in. Nothing
    /// is trusted until the checksum matches, the app is ours, newer, runnable here and intact.
    static func stage(zip: URL, expectedSHA256: String, into stage: URL, currentVersion: String) async throws -> URL {
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual.lowercased() == expectedSHA256.lowercased() else {
            throw UpdateError("The download is damaged (its checksum does not match). Try again.")
        }
        let out = stage.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let unzip = await Proc.capture(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, out.path])
        guard unzip.status == 0 else { throw UpdateError("Could not unpack the download. \(unzip.output)") }

        let app = out.appendingPathComponent("GetVideo.app", isDirectory: true)
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError("The download does not contain GetVideo.app.")
        }
        guard plist["CFBundleIdentifier"] as? String == bundleIdentifier else {
            throw UpdateError("The download is not GetVideo.")
        }
        let version = plist["CFBundleShortVersionString"] as? String ?? "0"
        guard isNewer(version, than: currentVersion) else {
            throw UpdateError("The download (\(version)) is not newer than this version (\(currentVersion)).")
        }
        if let minimum = plist["LSMinimumSystemVersion"] as? String {
            let n = minimum.split(separator: ".").compactMap { Int($0) }
            let required = OperatingSystemVersion(majorVersion: n.first ?? 0, minorVersion: n.count > 1 ? n[1] : 0,
                                                  patchVersion: n.count > 2 ? n[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else {
                throw UpdateError("GetVideo \(version) needs macOS \(minimum) or later.")
            }
        }
        let verify = await Proc.capture(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path])
        guard verify.status == 0 else { throw UpdateError("The downloaded app is damaged (its signature does not verify).") }
        return app
    }

    /// Runs after this app has quit: arguments are the app's process id, the new app, the app to
    /// replace and the staging folder. The old app is kept aside until the new one is in place, and
    /// put back if the swap fails. GETVIDEO_NO_OPEN stops it opening the app (for tests).
    static let relaunchScript = #"""
    #!/bin/sh
    pid="$1"; new="$2"; target="$3"; stage="$4"
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
    backup="$target.old-$$"
    if mv "$target" "$backup"; then
      if mv "$new" "$target"; then
        rm -rf "$backup"
        xattr -dr com.apple.quarantine "$target" 2>/dev/null
      else
        mv "$backup" "$target"
      fi
    fi
    rm -rf "$stage"
    [ -n "$GETVIDEO_NO_OPEN" ] || open "$target"
    """#

    // MARK: Network

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    /// Reads GitHub's "latest release" answer.
    static func release(from data: Data) throws -> AppRelease {
        let r = try JSONDecoder().decode(Release.self, from: data)
        guard let zip = r.assets.first(where: { $0.name == zipName }).flatMap({ URL(string: $0.browser_download_url) }) else {
            throw UpdateError("The latest release has no \(zipName).")
        }
        let sums = r.assets.first(where: { $0.name == sumsName }).flatMap { URL(string: $0.browser_download_url) }
        return AppRelease(version: r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), zipURL: zip, sumsURL: sums)
    }

    private static func latestRelease() async throws -> AppRelease {
        // GETVIDEO_UPDATE_FEED points the check at another address, to try an update without publishing one.
        let feed = ProcessInfo.processInfo.environment["GETVIDEO_UPDATE_FEED"].flatMap(URL.init(string:))
        var req = URLRequest(url: feed ?? URL(string: "https://api.github.com/repos/davewat/getvideo/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("GetVideo", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError("GitHub answered \(code) for the latest GetVideo release") }
        return try release(from: data)
    }

    private static func downloadFile(from url: URL, to dst: URL) async throws {
        var req = URLRequest(url: url)
        req.setValue("GetVideo", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw UpdateError("Download of \(url.lastPathComponent) failed (HTTP \(code))")
        }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }
}
