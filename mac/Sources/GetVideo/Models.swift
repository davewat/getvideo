import Foundation

extension KeyedDecodingContainer {
    /// Replaces `value` with what the file holds for `key`, if it holds anything.
    func update<T: Decodable>(_ value: inout T, _ key: Key) throws {
        if let v = try decodeIfPresent(T.self, forKey: key) { value = v }
    }
}

// Option structs mirror the Go version's (options.go); the argument builders live in Args.swift.

struct DownloadOptions: Codable, Equatable {
    var maxHeight = 1080          // 0 = best available
    var audioOnly = false
    var audioFormat = "mp3"       // mp3, m4a, opus, flac, wav, best
    var mergeContainer = "mp4"    // mp4, mkv, webm, "" = yt-dlp default
    var formatSort = ""           // -S
    var customFormat = ""         // -f, overrides the quality choice
    var noPlaylist = true
    var keepDownload = true       // keep the download until it is converted, so a failed conversion can resume
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

/// Reads files saved by earlier versions: anything missing keeps its default.
extension DownloadOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.update(&maxHeight, .maxHeight)
        try c.update(&audioOnly, .audioOnly)
        try c.update(&audioFormat, .audioFormat)
        try c.update(&mergeContainer, .mergeContainer)
        try c.update(&formatSort, .formatSort)
        try c.update(&customFormat, .customFormat)
        try c.update(&noPlaylist, .noPlaylist)
        try c.update(&keepDownload, .keepDownload)
        try c.update(&subtitles, .subtitles)
        try c.update(&autoSubs, .autoSubs)
        try c.update(&subLangs, .subLangs)
        try c.update(&embedSubs, .embedSubs)
        try c.update(&embedMetadata, .embedMetadata)
        try c.update(&embedThumbnail, .embedThumbnail)
        try c.update(&cookiesBrowser, .cookiesBrowser)
        try c.update(&rateLimit, .rateLimit)
        try c.update(&proxy, .proxy)
        try c.update(&sponsorBlock, .sponsorBlock)
        try c.update(&extraArgs, .extraArgs)
    }
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
    var trimMode = ""             // "" = keep it all, "duration" = shorten to a length, "percent" = to a percentage
    var trimLength = ""           // e.g. "3:00:00" (duration mode)
    var trimPercent = 50.0        // 1-100 (percent mode)
    var trimKeep = "first"        // which part to keep: first, last or middle
    var extraArgs = ""
}

/// Reads files saved by earlier versions: anything missing keeps its default.
extension TranscodeOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.update(&skip, .skip)
        try c.update(&preset, .preset)
        try c.update(&container, .container)
        try c.update(&encoder, .encoder)
        try c.update(&qualityMode, .qualityMode)
        try c.update(&quality, .quality)
        try c.update(&videoBitrate, .videoBitrate)
        try c.update(&encoderPreset, .encoderPreset)
        try c.update(&framerate, .framerate)
        try c.update(&framerateMode, .framerateMode)
        try c.update(&maxWidth, .maxWidth)
        try c.update(&maxHeight, .maxHeight)
        try c.update(&deinterlace, .deinterlace)
        try c.update(&audioEncoder, .audioEncoder)
        try c.update(&audioBitrate, .audioBitrate)
        try c.update(&allAudio, .allAudio)
        try c.update(&allSubs, .allSubs)
        try c.update(&webOptimize, .webOptimize)
        try c.update(&trimMode, .trimMode)
        try c.update(&trimLength, .trimLength)
        try c.update(&trimPercent, .trimPercent)
        try c.update(&trimKeep, .trimKeep)
        try c.update(&extraArgs, .extraArgs)
    }
}

struct OutputOptions: Codable, Equatable {
    var dir = ""                  // "" = ~/Downloads
    var filename = ""             // without extension; "" = video title. Never saved as a default.
    var keepSource = false
    var overwrite = false
}

/// Reads files saved by earlier versions: anything missing keeps its default.
extension OutputOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.update(&dir, .dir)
        try c.update(&filename, .filename)
        try c.update(&keepSource, .keepSource)
        try c.update(&overwrite, .overwrite)
    }
}

/// How a guide (a PDF written from a video's captions) is made. The API key is not here: it lives
/// in the Keychain (Keychain.swift) and is never written to the settings or the job history.
struct GuideOptions: Codable, Equatable {
    static let styles = ["full", "summary", "notes", "tutorial"]
    static let providers = GuideProvider.all.map(\.id)
    static let maxScreenshots = 30

    var style = "full"            // full, summary (at most 3 screenshots), notes, tutorial
    var dark = false
    var largeText = false
    var provider = "anthropic"    // a GuideProvider id
    var model = ""                // "" = the provider's default
    var baseURL = ""              // "" = the provider's default
    var maxShots = 20             // most screenshots in the guide
    var freeOnly = true           // the Model menu lists only free models, where the service says which are free

    var effectiveModel: String {
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return !m.isEmpty ? m : GuideProvider.named(provider).defaultModel
    }

    var effectiveBaseURL: String {
        let u = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = !u.isEmpty ? u : GuideProvider.named(provider).baseURL
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    /// The screenshots this guide may hold: the summary style keeps it to three.
    var effectiveShots: Int {
        let n = min(max(maxShots, 0), Self.maxScreenshots)
        return style == "summary" ? min(n, 3) : n
    }

    /// True when the base URL points at this computer, where a local model needs no API key.
    var isLocal: Bool {
        guard let host = URL(string: effectiveBaseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

/// Reads files saved by earlier versions: anything missing keeps its default.
extension GuideOptions {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.update(&style, .style)
        try c.update(&dark, .dark)
        try c.update(&largeText, .largeText)
        try c.update(&provider, .provider)
        try c.update(&model, .model)
        try c.update(&baseURL, .baseURL)
        try c.update(&maxShots, .maxShots)
        try c.update(&freeOnly, .freeOnly)
    }
}

/// One complete set of options: what a job runs with, and what "Save as default" stores.
struct Settings: Codable, Equatable {
    var download = DownloadOptions()
    var transcode = TranscodeOptions()
    var output = OutputOptions()
    var guide = GuideOptions()

    /// True when this set of options runs the Convert stage.
    var converts: Bool { !download.audioOnly && !transcode.skip }
}

/// Reads files saved by earlier versions: anything missing keeps its default.
extension Settings {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try c.update(&download, .download)
        try c.update(&transcode, .transcode)
        try c.update(&output, .output)
        try c.update(&guide, .guide)
    }
}

enum JobStatus: String, Codable {
    // writing, capturing and rendering are the guide stages; a guide's captions are fetched while "downloading"
    case queued, downloading, converting, saving, done, failed, canceled, writing, capturing, rendering

    var isActive: Bool { self == .queued || self == .downloading || self == .converting || self == .saving || inGuide }

    /// A stage only a guide job goes through.
    var inGuide: Bool { self == .writing || self == .capturing || self == .rendering }

    /// What to call the stage for a guide job, whose "downloading" is getting the captions.
    func label(guide: Bool) -> String {
        guard guide else { return label }
        return self == .downloading ? "Getting captions" : label
    }

    var label: String {
        switch self {
        case .queued: "Waiting"
        case .writing: "Writing"
        case .capturing: "Screenshots"
        case .rendering: "Rendering"
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
    var url: String               // empty for a file edited on this computer
    var source = ""              // a file on this computer to edit with HandBrake, instead of a download
    var guide = false             // make a PDF guide from the video's captions instead of downloading it
    var title: String             // the URL until yt-dlp reports the real title
    var status: JobStatus = .queued
    var percent = 0.0             // progress of the current stage, 0...100
    var speed = ""
    var eta = ""
    var error: String?
    var outputs: [String] = []    // absolute paths of the finished files
    var downloads: [String] = []  // downloaded files kept for a conversion that has not finished
    var log: [String] = []
    var settings: Settings
    var created = Date()
}

/// Reads job history saved by earlier versions: anything missing keeps its default.
extension Job {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        settings = try c.decode(Settings.self, forKey: .settings)
        try c.update(&id, .id)
        try c.update(&status, .status)
        try c.update(&percent, .percent)
        try c.update(&speed, .speed)
        try c.update(&eta, .eta)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        try c.update(&outputs, .outputs)
        try c.update(&downloads, .downloads)
        try c.update(&source, .source)
        try c.update(&guide, .guide)
        try c.update(&log, .log)
        try c.update(&created, .created)
    }
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
    var checkError: String?       // why the last look for a newer version failed
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
