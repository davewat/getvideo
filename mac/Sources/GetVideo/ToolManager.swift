import Combine
import CryptoKit
import Foundation

/// Installs and updates yt-dlp, HandBrakeCLI and ffmpeg. A port of tools.go.
@MainActor
final class ToolManager: ObservableObject {
    /// Always one entry per ToolName, in ToolName.allCases order.
    @Published private(set) var tools: [Tool] = ToolName.allCases.map { Tool(name: $0) }
    /// HandBrake's presets, grouped by category; empty until HandBrakeCLI is installed.
    @Published private(set) var presets: [PresetGroup] = []
    /// False until the first `refresh` has finished, so the UI can tell "unknown" from "missing".
    @Published private(set) var loaded = false

    private let binDir: URL
    private let installer: ToolInstaller
    /// The HandBrakeCLI version `presets` was read from; nil until they have been read.
    private var presetsVersion: String?

    init(binDir: URL = AppPaths.bin) {
        self.binDir = binDir
        installer = ToolInstaller(binDir: binDir)
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    }

    /// True when every tool is installed.
    var ready: Bool { tools.allSatisfy(\.installed) }

    func path(_ name: ToolName) -> URL { binDir.appendingPathComponent(name.rawValue) }

    /// Re-reads what is installed; with checkLatest, also asks the network for the newest versions.
    func refresh(checkLatest: Bool) async {
        readInstalled()
        await loadPresets()
        if checkLatest {
            // A failed check leaves `latest` as it was: being offline is not an error.
            let installer = installer
            await withTaskGroup(of: (ToolName, String?).self) { group in
                for name in ToolName.allCases {
                    group.addTask { (name, try? await installer.latest(name)) }
                }
                for await (name, version) in group {
                    if let version, !version.isEmpty { update(name) { $0.latest = version } }
                }
            }
        }
        loaded = true
    }

    /// Downloads (or updates) one tool. Failures land in that tool's `error`, never thrown.
    func install(_ name: ToolName) async {
        guard let tool = tools.first(where: { $0.name == name }), !tool.busy else { return }
        update(name) {
            $0.busy = true
            $0.error = nil
        }
        var failure: String?
        do {
            let version = try await installer.install(name)
            // What was just installed is the newest there is, whatever the last check said.
            update(name) { $0.latest = version }
        } catch {
            failure = error.localizedDescription
        }
        readInstalled()
        update(name) {
            $0.busy = false
            $0.error = failure
        }
        if name == .handbrake { await loadPresets() }
    }

    /// Easy mode's start-up step: refresh(checkLatest: true), then install whatever is missing or stale.
    func autoUpdate() async {
        await refresh(checkLatest: true)
        let stale = tools.filter { !$0.installed || $0.updateAvailable }.map(\.name)
        await withTaskGroup(of: Void.self) { group in
            for name in stale {
                group.addTask { await self.install(name) }
            }
        }
    }

    // MARK: Private

    private func update(_ name: ToolName, _ change: (inout Tool) -> Void) {
        guard let i = tools.firstIndex(where: { $0.name == name }) else { return }
        change(&tools[i])
    }

    /// Reads `bin/<tool>` and `bin/<tool>.version` for every tool.
    private func readInstalled() {
        for name in ToolName.allCases {
            let installed = ToolInstaller.isFile(path(name))
            var version = ""
            if installed, let text = try? String(contentsOf: path(name).appendingPathExtension("version"), encoding: .utf8) {
                version = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            update(name) {
                $0.installed = installed
                $0.version = version
            }
        }
    }

    /// Asks HandBrakeCLI for its presets, once per installed version.
    private func loadPresets() async {
        guard let hb = tools.first(where: { $0.name == .handbrake }), hb.installed else {
            presets = []
            presetsVersion = nil
            return
        }
        if presetsVersion == hb.version, !presets.isEmpty { return }
        // The list is printed on stderr; capture merges both streams.
        let result = await Proc.capture(path(.handbrake), ["--preset-list"])
        let groups = Parsing.presetList(result.output)
        guard !groups.isEmpty else { return }
        presets = groups
        presetsVersion = hb.version
    }
}

/// A download or install step that failed; the message is shown in the Tools panel.
struct ToolError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The network and file work behind ToolManager. Not tied to any actor, so none of it runs on
/// the main thread.
struct ToolInstaller: Sendable {
    let binDir: URL

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    /// Refuses every redirect, so the 3xx response itself (and its Location header) comes back.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: c)
    }()

    private static var ffmpegURL: URL {
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "amd64"
        #endif
        // Martin Riedl's static macOS build server; it serves arm64 and amd64.
        return URL(string: "https://ffmpeg.martin-riedl.de/redirect/latest/macos/\(arch)/release/ffmpeg.zip")!
    }

    static func isFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    private func path(_ file: String) -> URL { binDir.appendingPathComponent(file) }

    private static func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("getvideo", forHTTPHeaderField: "User-Agent")
        return r
    }

    // MARK: Newest versions

    private func release(_ repo: String) async throws -> Release {
        var req = Self.request(URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await Self.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ToolError(message: "GitHub answered \(code) for the latest \(repo) release") }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Where the "latest" ffmpeg link points right now, and the version named in that address.
    private func ffmpegLatest() async throws -> (version: String, url: URL) {
        let (_, resp) = try await Self.session.data(for: Self.request(Self.ffmpegURL), delegate: NoRedirect())
        guard let location = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location"),
              let version = Parsing.ffmpegVersion(fromLocation: location),
              let url = URL(string: location, relativeTo: Self.ffmpegURL)?.absoluteURL
        else { throw ToolError(message: "Unexpected answer from the ffmpeg download server") }
        return (version, url)
    }

    func latest(_ name: ToolName) async throws -> String {
        switch name {
        case .ytdlp: try await release("yt-dlp/yt-dlp").tag_name
        case .handbrake: try await release("HandBrake/HandBrake").tag_name
        case .ffmpeg: try await ffmpegLatest().version
        }
    }

    // MARK: Installing

    /// Downloads and installs the newest build of a tool; returns the version it recorded.
    func install(_ name: ToolName) async throws -> String {
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        switch name {
        case .ytdlp: return try await installYtdlp()
        case .handbrake: return try await installHandbrake()
        case .ffmpeg: return try await installFfmpeg()
        }
    }

    private func download(_ url: URL, to dst: URL) async throws {
        let (tmp, resp) = try await Self.session.download(for: Self.request(url))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ToolError(message: "Download of \(url.lastPathComponent) failed (HTTP \(code))")
        }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
    }

    private static func sha256(_ file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Atomically moves a finished binary into the tools folder and records its version.
    private func place(_ name: ToolName, _ src: URL, version: String) async throws {
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: src.path)
        // Downloaded executables can carry a quarantine flag that blocks launching them.
        _ = await Proc.capture(URL(fileURLWithPath: "/usr/bin/xattr"), ["-d", "com.apple.quarantine", src.path])
        let dst = path(name.rawValue)
        guard rename(src.path, dst.path) == 0 else {
            throw ToolError(message: "Could not move \(name.rawValue) into place: \(String(cString: strerror(errno)))")
        }
        try Data((version + "\n").utf8).write(to: dst.appendingPathExtension("version"), options: .atomic)
    }

    private func installYtdlp() async throws -> String {
        let r = try await release("yt-dlp/yt-dlp")
        guard let bin = r.assets.first(where: { $0.name == "yt-dlp_macos" }), let binURL = URL(string: bin.browser_download_url) else {
            throw ToolError(message: "No yt-dlp_macos file in the latest yt-dlp release")
        }
        guard let sums = r.assets.first(where: { $0.name == "SHA2-256SUMS" }), let sumsURL = URL(string: sums.browser_download_url) else {
            throw ToolError(message: "No checksum file in the latest yt-dlp release")
        }
        let tmp = path(".yt-dlp.download"), sumsFile = path(".yt-dlp.sums")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: sumsFile)
        }
        try await download(binURL, to: tmp)
        try await download(sumsURL, to: sumsFile)
        let want = Parsing.checksum(in: (try? String(contentsOf: sumsFile, encoding: .utf8)) ?? "", asset: "yt-dlp_macos")
        let got = try Self.sha256(tmp)
        guard let want, want.lowercased() == got else {
            throw ToolError(message: "The yt-dlp download did not match its checksum (expected \(want ?? "none listed"), got \(got))")
        }
        try await place(.ytdlp, tmp, version: r.tag_name)
        return r.tag_name
    }

    private func installHandbrake() async throws -> String {
        let r = try await release("HandBrake/HandBrake")
        guard let asset = r.assets.last(where: { $0.name.hasPrefix("HandBrakeCLI-") && $0.name.hasSuffix(".dmg") }),
              let dmgURL = URL(string: asset.browser_download_url)
        else { throw ToolError(message: "No HandBrakeCLI disk image in the latest HandBrake release") }

        let fm = FileManager.default
        let work = path(".hb-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let dmg = work.appendingPathComponent("hb.dmg"), mnt = work.appendingPathComponent("mnt")
        try await download(dmgURL, to: dmg)
        try fm.createDirectory(at: mnt, withIntermediateDirectories: true)

        let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
        let attach = await Proc.capture(hdiutil, ["attach", "-nobrowse", "-readonly", "-noverify", "-mountpoint", mnt.path, dmg.path])
        guard attach.status == 0 else {
            throw ToolError(message: "Could not open the HandBrakeCLI disk image: \(attach.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let tmp = path(".hb.download")
        defer { try? fm.removeItem(at: tmp) }
        var copyError: Error?
        do {
            let src = mnt.appendingPathComponent("HandBrakeCLI")
            guard Self.isFile(src) else { throw ToolError(message: "HandBrakeCLI not found inside the disk image") }
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: src, to: tmp)
        } catch {
            copyError = error
        }
        _ = await Proc.capture(hdiutil, ["detach", "-force", mnt.path])
        if let copyError { throw copyError }
        try await place(.handbrake, tmp, version: r.tag_name)
        return r.tag_name
    }

    private func installFfmpeg() async throws -> String {
        let (version, url) = try await ffmpegLatest()
        let fm = FileManager.default
        let work = path(".ff-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let zip = work.appendingPathComponent("ffmpeg.zip"), out = work.appendingPathComponent("out")
        try await download(url, to: zip)
        let unzip = await Proc.capture(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, out.path])
        guard unzip.status == 0 else {
            throw ToolError(message: "Could not unpack ffmpeg: \(unzip.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var found: URL?
        if let walk = fm.enumerator(at: out, includingPropertiesForKeys: nil) {
            while let f = walk.nextObject() as? URL {
                if f.lastPathComponent == "ffmpeg", Self.isFile(f) {
                    found = f
                    break
                }
            }
        }
        guard let found else { throw ToolError(message: "ffmpeg not found in the downloaded archive") }
        let tmp = path(".ffmpeg.download")
        defer { try? fm.removeItem(at: tmp) }
        try? fm.removeItem(at: tmp)
        try fm.moveItem(at: found, to: tmp)
        try await place(.ffmpeg, tmp, version: version)
        return version
    }
}
