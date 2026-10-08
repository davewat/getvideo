import XCTest
@testable import GetVideo

/// A fresh folder under the system temp directory, removed when the test ends.
func makeTempDir(_ test: XCTestCase) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("getvideo-tests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
}

// Ports of options_test.go.
final class ArgsTests: XCTestCase {
    func testSplitArgs() throws {
        XCTAssertEqual(try Args.split(#"--a "b c" 'd e' f="""#), ["--a", "b c", "d e", "f="])
        XCTAssertEqual(try Args.split(""), [])
        XCTAssertEqual(try Args.split(#"a "" b"#), ["a", "", "b"])
        XCTAssertThrowsError(try Args.split(#""open"#)) { error in
            XCTAssertEqual(error.localizedDescription, "unterminated quote")
        }
    }

    func testDownloadArgs() throws {
        var o = DownloadOptions(maxHeight: 720, audioOnly: false, audioFormat: "", mergeContainer: "mp4", noPlaylist: true,
                                subLangs: "", embedMetadata: false, extraArgs: "--retries 3")
        XCTAssertEqual(try Args.download(o),
                       ["-f", "bv*[height<=720]+ba/b[height<=720]", "--merge-output-format", "mp4", "--no-playlist", "--retries", "3"])

        o = DownloadOptions(maxHeight: 0, audioOnly: true, audioFormat: "mp3", mergeContainer: "", noPlaylist: false,
                            subLangs: "", embedMetadata: false)
        XCTAssertEqual(try Args.download(o), ["-f", "ba/b", "-x", "--audio-format", "mp3"])

        o.extraArgs = "'open"
        XCTAssertThrowsError(try Args.download(o)) { error in
            XCTAssertEqual(error.localizedDescription, "yt-dlp extra args: unterminated quote")
        }
    }

    func testDownloadArgsOrder() throws {
        let o = DownloadOptions(maxHeight: 1080, formatSort: "res", subtitles: true, autoSubs: true, subLangs: "en,es",
                                embedSubs: true, embedMetadata: true, embedThumbnail: true, cookiesBrowser: "safari",
                                rateLimit: "2M", proxy: "socks5://x", sponsorBlock: ["sponsor", "intro"])
        XCTAssertEqual(try Args.download(o), [
            "-f", "bv*[height<=1080]+ba/b[height<=1080]", "-S", "res", "--merge-output-format", "mp4", "--no-playlist",
            "--write-subs", "--write-auto-subs", "--sub-langs", "en,es", "--embed-subs", "--embed-metadata",
            "--embed-thumbnail", "--cookies-from-browser", "safari", "-r", "2M", "--proxy", "socks5://x",
            "--sponsorblock-remove", "sponsor,intro",
        ])
    }

    func testTranscodeArgs() throws {
        var o = TranscodeOptions(preset: "Fast 1080p30", container: "mkv", qualityMode: "rf", quality: 20,
                                 framerateMode: "", maxWidth: 1280, webOptimize: true)
        XCTAssertEqual(try Args.transcode(o),
                       ["--preset", "Fast 1080p30", "-f", "av_mkv", "-q", "20", "--maxWidth", "1280", "--optimize"])
        o.quality = 20.5
        XCTAssertTrue(try Args.transcode(o).contains("20.5"))

        o = TranscodeOptions(preset: "", container: "", qualityMode: "bitrate", videoBitrate: 0, framerateMode: "", webOptimize: false)
        XCTAssertThrowsError(try Args.transcode(o), "bitrate mode without a bitrate must fail") { error in
            XCTAssertEqual(error.localizedDescription, "video bitrate must be > 0")
        }
        o.videoBitrate = 2500
        XCTAssertEqual(try Args.transcode(o), ["-b", "2500"])
    }
}

final class ParsingTests: XCTestCase {
    func testParsePresetList() {
        let g = Parsing.presetList("General/\n    Fast 1080p30\n        H.264 desc\n    Fast 720p30\nWeb/\r\n    Discord Small\r\n")
        XCTAssertEqual(g, [
            PresetGroup(category: "General", presets: ["Fast 1080p30", "Fast 720p30"]),
            PresetGroup(category: "Web", presets: ["Discord Small"]),
        ])
        XCTAssertEqual(Parsing.presetList("[10:00:00] hb_init: starting\n    Orphan\n"), [])
    }

    func testSanitize() {
        XCTAssertEqual(Parsing.sanitize("../a/b: c"), "-a-b- c")
        XCTAssertEqual(Parsing.sanitize(""), "video")
        XCTAssertEqual(Parsing.sanitize("  ...  "), "video")
        XCTAssertEqual(Parsing.sanitize("a\tb\u{01}c"), "a-b-c")
        let long = Parsing.sanitize(String(repeating: "é", count: 200))
        XCTAssertLessThanOrEqual(long.utf8.count, 180)
        XCTAssertEqual(long.count, 90)
    }

    func testHandBrakeProgress() {
        XCTAssertEqual(Parsing.handBrakeProgress("Encoding: task 1 of 1, 12.34 % (56.78 fps, avg 60.12 fps, ETA 00h01m23s)"),
                       Parsing.HBProgress(percent: 12.34, fps: "56.78", eta: "00h01m23s"))
        XCTAssertEqual(Parsing.handBrakeProgress("Encoding: task 2 of 2, 0.50 %"),
                       Parsing.HBProgress(percent: 0.5, fps: nil, eta: nil))
        XCTAssertNil(Parsing.handBrakeProgress("[12:00:00] starting job"))
        XCTAssertNil(Parsing.handBrakeProgress("Encoding: something else"))
    }

    func testYtdlpProgress() {
        XCTAssertEqual(Parsing.ytdlpProgress("  45.2%|   1.20MiB/s|00:10"),
                       Parsing.YTProgress(percent: 45.2, speed: "1.20MiB/s", eta: "00:10"))
        XCTAssertEqual(Parsing.ytdlpProgress("N/A|N/A|Unknown"), Parsing.YTProgress(percent: nil, speed: "N/A", eta: "Unknown"))
        XCTAssertNil(Parsing.ytdlpProgress("45%|x"))
    }

    func testChecksumLookup() {
        let sums = """
        aaa111  yt-dlp
        bbb222  yt-dlp_macos
        ccc333 *yt-dlp_macos.zip
        ddd444  yt-dlp_macos_legacy
        not a sums line at all
        """
        XCTAssertEqual(Parsing.checksum(in: sums, asset: "yt-dlp_macos"), "bbb222")
        XCTAssertEqual(Parsing.checksum(in: sums, asset: "yt-dlp_macos.zip"), "ccc333")
        XCTAssertNil(Parsing.checksum(in: sums, asset: "yt-dlp_linux"))
        XCTAssertNil(Parsing.checksum(in: "", asset: "yt-dlp_macos"))
    }

    func testFfmpegVersion() {
        XCTAssertEqual(Parsing.ffmpegVersion(fromLocation: "/download/macos/arm64/1759000000_8.0/ffmpeg.zip"), "1759000000_8.0")
        XCTAssertEqual(Parsing.ffmpegVersion(fromLocation: "https://h/download/macos/arm64/1_7.1/ffmpeg.zip"), "1_7.1")
        XCTAssertNil(Parsing.ffmpegVersion(fromLocation: ""))
        XCTAssertNil(Parsing.ffmpegVersion(fromLocation: "ffmpeg.zip"))
    }

    func testOutputName() {
        let src = URL(fileURLWithPath: "/w/abc123.mp4")
        XCTAssertEqual(Parsing.outputName(custom: "", title: "My Video", url: "https://x", source: src, fileCount: 1), "My Video")
        XCTAssertEqual(Parsing.outputName(custom: "Mine", title: "My Video", url: "https://x", source: src, fileCount: 1), "Mine")
        // The title is still the URL when yt-dlp never reported one.
        XCTAssertEqual(Parsing.outputName(custom: "", title: "https://x", url: "https://x", source: src, fileCount: 1), "abc123")
        // A playlist: every file keeps its own name.
        XCTAssertEqual(Parsing.outputName(custom: "Mine", title: "Last Title", url: "https://x", source: src, fileCount: 3), "abc123")
    }

    func testDestinationNaming() throws {
        let dir = try makeTempDir(self)
        func touch(_ name: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()) }
        func name(overwrite: Bool = false) -> String {
            Parsing.destination(dir: dir, name: "clip", ext: ".mp4", overwrite: overwrite).lastPathComponent
        }
        XCTAssertEqual(name(), "clip.mp4")
        touch("clip.mp4")
        XCTAssertEqual(name(), "clip (1).mp4")
        touch("clip (1).mp4")
        XCTAssertEqual(name(), "clip (2).mp4")
        XCTAssertEqual(name(overwrite: true), "clip.mp4")
        XCTAssertEqual(Parsing.destination(dir: dir, name: "clip", ext: "", overwrite: false).lastPathComponent, "clip")
    }

    func testMoveInto() throws {
        let dir = try makeTempDir(self)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func source(_ text: String) throws -> URL {
            let u = dir.appendingPathComponent("abc.mkv")
            try Data(text.utf8).write(to: u)
            return u
        }
        XCTAssertEqual(try Parsing.move(source("one"), into: out, name: "Film", overwrite: false).lastPathComponent, "Film.mkv")
        XCTAssertEqual(try Parsing.move(source("two"), into: out, name: "Film", overwrite: false).lastPathComponent, "Film (1).mkv")
        XCTAssertEqual(try Parsing.move(source("three"), into: out, name: "Film", overwrite: true).lastPathComponent, "Film.mkv")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Film.mkv"), encoding: .utf8), "three")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Film (1).mkv"), encoding: .utf8), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("abc.mkv").path))
    }
}

/// Collects lines from background threads.
final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    func add(_ s: String) {
        lock.lock()
        _lines.append(s)
        lock.unlock()
    }
    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _lines
    }
}

final class ProcTests: XCTestCase {
    private let sh = URL(fileURLWithPath: "/bin/sh")

    func testLineSplitterMixedSeparators() {
        let s = Proc.LineSplitter()
        var got = s.feed(Data("one\rtwo\r\n  three  \n\n\rfo".utf8))
        XCTAssertEqual(got, ["one", "two", "three"])
        got = s.feed(Data("ur\rlast".utf8))
        XCTAssertEqual(got, ["four"])
        XCTAssertEqual(s.finish(), ["last"])
        XCTAssertEqual(s.finish(), [])
    }

    func testLineSplitterKeepsSplitCharacters() {
        // A multi-byte character cut in half by a read boundary must come out whole.
        let bytes = Array("héllo\n".utf8)
        let s = Proc.LineSplitter()
        XCTAssertEqual(s.feed(Data(bytes[0..<2])), [])
        XCTAssertEqual(s.feed(Data(bytes[2...])), ["héllo"])
    }

    func testRunMergesStreamsAndSplitsOnCarriageReturns() async throws {
        let box = LineBox()
        try await Proc.run(sh, ["-c", #"printf 'a\rb\n'; printf 'err\n' >&2; printf 'tail'"#]) { box.add($0) }
        XCTAssertEqual(box.lines.sorted(), ["a", "b", "err", "tail"])
    }

    func testRunReportsExitCode() async {
        do {
            try await Proc.run(sh, ["-c", "echo hi; exit 3"]) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "sh exited with code 3")
        }
    }

    func testRunMissingExecutable() async {
        do {
            try await Proc.run(URL(fileURLWithPath: "/nonexistent/tool"), []) { _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Could not start tool"), error.localizedDescription)
        }
    }

    func testCancelInterruptsTheProcess() async throws {
        let box = LineBox()
        let sh = sh
        let task = Task {
            try await Proc.run(sh, ["-c", "echo started; exec sleep 30"]) { box.add($0) }
        }
        let start = Date()
        while box.lines.isEmpty, Date().timeIntervalSince(start) < 5 { try await Task.sleep(nanoseconds: 20_000_000) }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 4, "SIGINT should stop it at once")
    }

    func testCancelBeforeStart() async {
        let sh = sh
        let task = Task {
            while !Task.isCancelled { await Task.yield() }   // the cancel lands before run() is called
            try await Proc.run(sh, ["-c", "sleep 30"]) { _ in }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCaptureKeepsIndentation() async {
        let r = await Proc.capture(sh, ["-c", #"printf 'A/\n    b\n' >&2"#])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.output, "A/\n    b\n")
    }
}
