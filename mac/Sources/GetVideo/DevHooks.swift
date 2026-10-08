import Foundation

/// Development aids, switched on by environment variables and inert otherwise. They let the app be
/// exercised without touching the real Application Support folder or ~/Downloads:
///
///   GETVIDEO_DATA=/path        keep tools, settings and history there (read by AppPaths)
///   GETVIDEO_ADD="url url"     queue these links at launch, with the saved defaults
///   GETVIDEO_ADD_DIR=/path     ...but save those into this folder
///
/// The mode can be forced the standard way: `GetVideo -mode advanced`.
@MainActor
enum DevHooks {
    static func start(settings: SettingsStore, queue: JobQueue) {
        let env = ProcessInfo.processInfo.environment
        guard let urls = env["GETVIDEO_ADD"]?.split(separator: " ").map(String.init), !urls.isEmpty else { return }
        var s = settings.saved
        if let dir = env["GETVIDEO_ADD_DIR"] { s.output.dir = dir }
        try? queue.add(urls: urls, settings: s)
    }
}
