import AppKit

/// Grows the window when Advanced opens, so the whole form and the sidebar are visible without
/// resizing by hand, and puts it back when returning to Easy.
@MainActor
enum WindowSizer {
    /// Wide enough for Advanced's two columns, tall enough for most of the form.
    private static let advancedSize = NSSize(width: 1180, height: 900)
    /// The frame the window had before it was grown; nil when it was already big enough.
    private static var easyFrame: NSRect?

    static func apply(mode: String, animate: Bool) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        guard mode == "advanced" else {
            if let frame = easyFrame { window.setFrame(frame, display: true, animate: animate) }
            easyFrame = nil
            return
        }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        var frame = window.frame
        let width = min(max(frame.width, advancedSize.width), screen.width)
        let height = min(max(frame.height, advancedSize.height), screen.height)
        guard width > frame.width || height > frame.height else { return }
        easyFrame = frame
        // Grow down and to the right from the title bar, then nudge back on screen if needed.
        frame.origin.y = frame.maxY - height
        frame.size = NSSize(width: width, height: height)
        frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - width)
        frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - height)
        window.setFrame(frame, display: true, animate: animate)
    }
}
