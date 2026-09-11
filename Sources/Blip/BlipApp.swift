import AppKit
import BlipCore

/// AppKit's entry point rather than SwiftUI's `App`.
///
/// `MenuBarExtra` is the idiomatic way to put a SwiftUI app in the menu bar and
/// it was what Blip used, but it hosts its label in an `NSHostingView` and
/// charges Auto Layout for every update — measurably, about a third of this
/// app's entire CPU budget, to re-derive a width that cannot change. The panel
/// is still SwiftUI; only the status item is hand-built. See
/// `StatusItemController` for the measurements.
@main
enum Blip {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // The delegate is the only strong reference to the monitor and the
        // status item, and `NSApplication.delegate` is weak.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitor: NetworkMonitor?
    private var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon and no menu bar menu. `LSUIElement` in Info.plist covers
        // this at launch; setting it here too keeps `swift run` — which has no
        // Info.plist — behaving the same as the bundle.
        NSApp.setActivationPolicy(.accessory)

        let monitor = NetworkMonitor()
        let settings = AppSettings()
        self.monitor = monitor
        controller = StatusItemController(monitor: monitor, settings: settings)
    }
}
