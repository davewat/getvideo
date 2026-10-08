import Foundation

/// The saved defaults (what Easy mode runs with) and the Advanced form's working copy.
@MainActor
final class SettingsStore: ObservableObject {
    /// What "Save as default" last stored, or the built-in defaults.
    @Published private(set) var saved = Settings()
    /// False while still on the built-in defaults.
    @Published private(set) var hasSaved = false
    /// The Advanced form edits this; it only becomes `saved` on `saveDraftAsDefault()`.
    @Published var draft = Settings()

    private let file: URL

    init(file: URL = AppPaths.settingsFile) {
        self.file = file
        if let data = try? Data(contentsOf: file), let v = try? JSONDecoder().decode(Settings.self, from: data) {
            saved = v
            hasSaved = true
        }
        draft = saved
    }

    /// True when the Advanced form differs from the saved defaults (the file name never counts).
    var isDirty: Bool { Self.withoutFilename(draft) != saved }

    func saveDraftAsDefault() throws {
        let v = Self.withoutFilename(draft)
        _ = try Args.download(v.download)
        _ = try Args.transcode(v.transcode)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(v).write(to: file, options: .atomic)
        saved = v
        hasSaved = true
    }

    func resetToBuiltIn() {
        try? FileManager.default.removeItem(at: file)
        saved = Settings()
        draft = saved
        hasSaved = false
    }

    private static func withoutFilename(_ s: Settings) -> Settings {
        var v = s
        v.output.filename = ""
        return v
    }
}
