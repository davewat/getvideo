import Foundation

// Option structs mirror the Go version's (options.go); the argument builders live in Args.swift.

struct DownloadOptions: Codable, Equatable {
    var maxHeight = 1080          // 0 = best available
    var audioOnly = false
    var audioFormat = "mp3"       // mp3, m4a, opus, flac, wav, best
    var mergeContainer = "mp4"    // mp4, mkv, webm, "" = yt-dlp default
    var formatSort = ""           // -S
    var customFormat = ""         // -f, overrides the quality choice
    var noPlaylist = true
    var subtitles = false
    var autoSubs = false
    var subLangs = "en"
    var embedSubs = false
    var embedMetadata = true
    var embedThumbnail = false
    var cookiesBrowser = ""       // safari, chrome, firefox, edge, brave
    var rateLimit = ""
    var proxy = ""
    var sponsorBlock: [String] = []
    var extraArgs = ""
}

struct TranscodeOptions: Codable, Equatable {
    var skip = false              // keep the download as it is
    var preset = "Fast 1080p30"
    var container = "mp4"         // mp4, mkv, webm
    var encoder = ""              // "" = preset default
    var qualityMode = ""          // "", rf, bitrate
    var quality = 22.0
    var videoBitrate = 4000       // kbps
    var encoderPreset = ""
    var framerate = ""            // "" = same as source
    var framerateMode = "vfr"     // vfr, cfr, pfr
    var maxWidth = 0
    var maxHeight = 0
    var deinterlace = ""          // "", decomb, yadif
    var audioEncoder = ""
    var audioBitrate = 0
    var allAudio = false
    var allSubs = false
    var webOptimize = true
    var extraArgs = ""
}

struct OutputOptions: Codable, Equatable {
    var dir = ""                  // "" = ~/Downloads
    var filename = ""             // without extension; "" = video title. Never saved as a default.
    var keepSource = false
    var overwrite = false
}

/// One complete set of options: what a job runs with, and what "Save as default" stores.
struct Settings: Codable, Equatable {
    var download = DownloadOptions()
    var transcode = TranscodeOptions()
    var output = OutputOptions()

    /// True when this set of options runs the Convert stage.
    var converts: Bool { !download.audioOnly && !transcode.skip }
}

enum JobStatus: String, Codable {
    case queued, downloading, converting, saving, done, failed, canceled

    var isActive: Bool { self == .queued || self == .downloading || self == .converting || self == .saving }

    var label: String {
        switch self {
        case .queued: "Waiting"
        case .downloading: "Downloading"
        case .converting: "Converting"
        case .saving: "Saving"
        case .done: "Done"
        case .failed: "Failed"
        case .canceled: "Canceled"
        }
    }
}

/// One URL's trip through download -> convert -> save.
struct Job: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: String
    var title: String             // the URL until yt-dlp reports the real title
    var status: JobStatus = .queued
    var percent = 0.0             // progress of the current stage, 0...100
    var speed = ""
    var eta = ""
    var error: String?
    var outputs: [String] = []    // absolute paths of the finished files
    var log: [String] = []
    var settings: Settings
    var created = Date()
}

enum ToolName: String, CaseIterable, Identifiable, Codable {
    case ytdlp = "yt-dlp"
    case handbrake = "HandBrakeCLI"
    case ffmpeg = "ffmpeg"
    var id: String { rawValue }
}

struct Tool: Identifiable, Equatable {
    let name: ToolName
    var installed = false
    var version = ""
    var latest = ""               // "" until an update check succeeds
    var busy = false              // an install or update is running
    var error: String?            // why the last install attempt failed
    var id: String { name.rawValue }
    var updateAvailable: Bool { installed && !latest.isEmpty && latest != version }
}

struct PresetGroup: Identifiable, Equatable {
    var category: String
    var presets: [String]
    var id: String { category }
}

/// Where the app keeps its files. `bin` is shared with the Go version of GetVideo (same layout:
/// `bin/<tool>` plus `bin/<tool>.version`); everything else is the Mac app's own.
enum AppPaths {
    static var root: URL {
        // GETVIDEO_DATA points the app at another folder, for development and testing.
        if let dir = ProcessInfo.processInfo.environment["GETVIDEO_DATA"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GetVideo", isDirectory: true)
    }
    static var bin: URL { root.appendingPathComponent("bin", isDirectory: true) }
    static var work: URL { root.appendingPathComponent("tmp-mac", isDirectory: true) }
    static var jobsFile: URL { root.appendingPathComponent("jobs-mac.json") }
    static var settingsFile: URL { root.appendingPathComponent("settings-mac.json") }
    static var downloads: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }
}
