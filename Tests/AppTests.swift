import AppKit
import Foundation

@main
struct AppTests {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = PluginPorterDelegate(inventoryLoader: { _, _ in [] })
        app.delegate = delegate
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        // Drain the fixture scan's main-queue completion without reading actual libraries.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let window = app.windows.first(where: { $0.title == "PluginPorter" }) else {
            fputs("FAIL: main window missing\n", stderr); exit(1)
        }
        // Keep a second window alive: closing the main window must not lose access to migration.
        let auxiliary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false
        auxiliary.orderFront(nil)
        var failures = 0
        func expect(_ condition: Bool, _ message: String) {
            print("\(condition ? "PASS" : "FAIL"): \(message)")
            if !condition { failures += 1 }
        }
        expect(!window.isReleasedWhenClosed, "Swift-owned main window survives close")
        // Disable the unsafe pre-fix ownership flag only in the test to exercise reopen separately.
        window.isReleasedWhenClosed = false
        window.close()
        expect(!window.isVisible, "main window closes while another window remains")
        let handled = (delegate as NSApplicationDelegate).applicationShouldHandleReopen?(app, hasVisibleWindows: true)
        expect(handled == false && window.isVisible, "Dock/Finder reopen restores the closed main window")
        expect(delegate.applicationShouldTerminateAfterLastWindowClosed(app), "closing the last window keeps the exit policy")
        let menus = app.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        expect(menus.contains { $0.keyEquivalent == "w" && $0.action == #selector(NSWindow.performClose(_:)) },
               "Command-W dispatches through the active window's close guard")
        expect(menus.contains { $0.keyEquivalent == "x" && $0.action == #selector(NSText.cut(_:)) },
               "Command-X is available to the active text field")
        window.close()
        auxiliary.close()
        withExtendedLifetime(delegate) { }
        exit(failures == 0 ? 0 : 1)
    }
}
