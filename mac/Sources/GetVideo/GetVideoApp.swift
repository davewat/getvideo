import SwiftUI

/// Quits with the last window and stops the running job's process on the way out.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var queue: JobQueue?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        queue?.shutdown()
    }
}

@main
struct GetVideoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings: SettingsStore
    @StateObject private var tools: ToolManager
    @StateObject private var queue: JobQueue

    init() {
        // The queue runs the tools the manager installs, so both are built from the same instance.
        let tools = ToolManager()
        _settings = StateObject(wrappedValue: SettingsStore())
        _tools = StateObject(wrappedValue: tools)
        _queue = StateObject(wrappedValue: JobQueue(tools: tools))
    }

    var body: some Scene {
        WindowGroup("GetVideo") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(tools)
                .environmentObject(queue)
                .frame(minWidth: 460, minHeight: 420)
                .onAppear {
                    delegate.queue = queue
                    DevHooks.start(settings: settings, queue: queue)
                }
        }
        .defaultSize(width: 720, height: 640)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {} // one window: no "New Window"
        }
    }
}
