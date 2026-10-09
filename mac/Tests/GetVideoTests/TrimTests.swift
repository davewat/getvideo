import XCTest
@testable import GetVideo

// Ports of trim_test.go.
final class TrimTests: XCTestCase {
    func testParseClock() {
        let ok: [String: Double] = [
            "3:00:00": 10800, "90:00": 5400, "0:45": 45, "1:02:03": 3723,
            "3h": 10800, "90m": 5400, "45s": 45, "1h30m": 5400, "1.5h": 5400, " 2 h 15 m ": 8100,
        ]
        for (input, want) in ok { XCTAssertEqual(Trim.parseClock(input), want, input) }
        for input in ["", "3", "abc", "1:2:3:4", "-5:00", "0", "0h", "3 hours", "3:", ":30", "30m1h"] {
            XCTAssertNil(Trim.parseClock(input), input)
        }
    }

    func testScanDuration() {
        let out = "[18:19:07] scan: decoding previews for title 1\n+ title 1:\n  + duration: 12:34:56\n    + 1: duration 00:00:05\n"
        XCTAssertEqual(Trim.scanDuration(out), 12 * 3600 + 34 * 60 + 56)
        XCTAssertNil(Trim.scanDuration("nothing here"))
    }

    /// The twelve-hour example: shorten to three hours, or to 25 percent.
    func testWindow() {
        let total = 12.0 * 3600
        func opts(_ mode: String, length: String = "", percent: Double = 50, keep: String = "first") -> TranscodeOptions {
            var o = TranscodeOptions()
            o.trimMode = mode; o.trimLength = length; o.trimPercent = percent; o.trimKeep = keep
            return o
        }
        func check(_ name: String, _ o: TranscodeOptions, _ start: Double?, _ length: Double?, line: UInt = #line) {
            let w = Trim.window(o, total: total)
            XCTAssertEqual(w?.start, start, name, line: line)
            XCTAssertEqual(w?.length, length, name, line: line)
        }
        check("first 3h", opts("duration", length: "3:00:00"), 0, 10800)
        check("last 3h", opts("duration", length: "3h", keep: "last"), 9 * 3600, 10800)
        check("middle 4h", opts("duration", length: "4h", keep: "middle"), 4 * 3600, 4 * 3600)
        check("25 percent", opts("percent", percent: 25), 0, 3 * 3600)
        check("last 50 percent", opts("percent", percent: 50, keep: "last"), 6 * 3600, 6 * 3600)
        check("longer than the video", opts("duration", length: "13h"), nil, nil)
        check("100 percent", opts("percent", percent: 100), nil, nil)
        check("off", opts(""), nil, nil)
    }

    func testArgsAndNeedsScan() {
        XCTAssertEqual(Trim.args(start: 0, length: 10800), ["--stop-at", "duration:10800"])
        XCTAssertEqual(Trim.args(start: 32400, length: 10800), ["--start-at", "duration:32400", "--stop-at", "duration:10800"])
        var o = TranscodeOptions()
        o.trimMode = "duration"
        XCTAssertFalse(Trim.needsScan(o), "the first part of a fixed length needs no scan")
        o.trimKeep = "last"
        XCTAssertTrue(Trim.needsScan(o))
        o.trimMode = "percent"; o.trimKeep = "first"
        XCTAssertTrue(Trim.needsScan(o))
    }

    func testValidation() throws {
        for (mode, length, percent, keep) in [("duration", "soon", 50.0, "first"), ("percent", "", 0.0, "first"), ("percent", "", 101.0, "first"),
                                              ("weekly", "", 50.0, "first"), ("duration", "1h", 50.0, "some")] {
            var o = TranscodeOptions()
            o.trimMode = mode; o.trimLength = length; o.trimPercent = percent; o.trimKeep = keep
            XCTAssertThrowsError(try Args.transcode(o), "\(mode) \(length) \(percent) \(keep)")
        }
        var o = TranscodeOptions()
        o.trimMode = "percent"; o.trimPercent = 50; o.trimKeep = "middle"
        XCTAssertNoThrow(try Args.transcode(o))
    }
}

/// Files saved by earlier versions have none of the new keys. They must still load, or a person's
/// saved defaults and job history would silently be thrown away.
final class LegacyFilesTests: XCTestCase {
    func testOldSettingsStillLoad() throws {
        let old = #"{"download":{"maxHeight":720,"audioOnly":false,"noPlaylist":false,"sponsorBlock":["intro"]},"transcode":{"preset":"HQ 1080p30 Surround","container":"mkv"},"output":{"dir":"/Volumes/Big","keepSource":true}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(old.utf8))
        XCTAssertEqual(s.download.maxHeight, 720)
        XCTAssertFalse(s.download.noPlaylist)
        XCTAssertEqual(s.download.sponsorBlock, ["intro"])
        XCTAssertEqual(s.transcode.preset, "HQ 1080p30 Surround")
        XCTAssertEqual(s.output.dir, "/Volumes/Big")
        XCTAssertTrue(s.output.keepSource)
        XCTAssertTrue(s.download.keepDownload, "kept downloads are on unless a person turned them off")
        XCTAssertEqual(s.transcode.trimMode, "")
        XCTAssertEqual(s.transcode.trimKeep, "first")
        XCTAssertTrue(s.transcode.webOptimize, "keys missing from the file keep their defaults")
    }

    func testOldJobHistoryStillLoads() throws {
        let id = UUID()
        let old = #"[{"id":"\#(id.uuidString)","url":"https://a.example/v","title":"Old","status":"done","percent":100,"speed":"","eta":"","outputs":["/x/Old.mp4"],"log":["l"],"settings":{"download":{},"transcode":{},"output":{}},"created":780000000}]"#
        let jobs = try JSONDecoder().decode([Job].self, from: Data(old.utf8))
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].id, id)
        XCTAssertEqual(jobs[0].status, .done)
        XCTAssertEqual(jobs[0].outputs, ["/x/Old.mp4"])
        XCTAssertEqual(jobs[0].downloads, [])
        XCTAssertNil(jobs[0].error)
    }

    func testRoundTrip() throws {
        var s = Settings()
        s.transcode.trimMode = "percent"
        s.transcode.trimPercent = 25
        s.download.keepDownload = false
        var job = Job(url: "https://a.example/v", title: "t", settings: s)
        job.downloads = ["/x/a.mp4"]
        let back = try JSONDecoder().decode(Job.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(back, job)
    }
}
