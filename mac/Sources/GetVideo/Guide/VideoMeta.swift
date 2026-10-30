import Foundation

/// What `yt-dlp -j` says about a video.
struct VideoMeta: Equatable {
    var id = ""
    var title = ""
    var channel = ""
    var duration = 0.0            // seconds; 0 when unknown
    var pageURL = ""
    var isYouTube = false
    var streamURL: String?        // a stream to take screenshots from
    var headers: [String: String] = [:]

    /// Reads yt-dlp's output: the first line that is a JSON object (the rest is warnings).
    static func parse(_ output: String) throws -> VideoMeta {
        let line = output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("{") }
        guard let line, let dict = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw JobError(message: "yt-dlp did not report the video's details")
        }
        var m = VideoMeta()
        m.id = dict["id"] as? String ?? ""
        m.title = dict["title"] as? String ?? ""
        m.channel = dict["channel"] as? String ?? dict["uploader"] as? String ?? ""
        m.duration = (dict["duration"] as? NSNumber)?.doubleValue ?? 0
        m.pageURL = dict["webpage_url"] as? String ?? ""
        m.isYouTube = (dict["extractor_key"] as? String)?.lowercased() == "youtube"
        // One format, or a video and an audio format to merge: either way a video stream is wanted.
        var format = dict
        if let formats = dict["requested_formats"] as? [[String: Any]] {
            format = formats.first { ($0["vcodec"] as? String ?? "none") != "none" } ?? formats.first ?? dict
        }
        m.streamURL = format["url"] as? String ?? dict["url"] as? String
        m.headers = (format["http_headers"] as? [String: String]) ?? (dict["http_headers"] as? [String: String]) ?? [:]
        return m
    }

    /// A link to this moment of the video, when the site has such links.
    func link(at seconds: Int) -> String? {
        if isYouTube, !id.isEmpty { return "https://youtu.be/\(id)?t=\(seconds)" }
        return nil
    }
}
