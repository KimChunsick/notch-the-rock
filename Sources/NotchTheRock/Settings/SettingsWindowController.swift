import AppKit
import SwiftUI

/// The Settings window, opened by the notch's gear button, its 설정… menu item and a reopen of the
/// running app. One window is kept and brought to the front again on every open.
@MainActor
final class SettingsWindowController {
    private let catalog: PluginCatalog
    private var window: NSWindow?

    init(catalog: PluginCatalog) {
        self.catalog = catalog
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.showInFront()
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(catalog: catalog)))
        window.title = "NotchTheRock 설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        return window
    }
}

extension NSWindow {
    /// Shows one of the app's own windows (Settings, onboarding) in front of the other apps and
    /// makes it key. The app is an accessory app and usually not active here. On macOS 14 and later
    /// `NSApp.activate()` is only a request that the system declines while the user works in
    /// another app, and the window then opens behind that app's windows;
    /// `activate(ignoringOtherApps:)` still activates the app (checked on macOS 26.5).
    func showInFront() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let catalog: PluginCatalog

    var body: some View {
        TabView {
            GeneralSettingsPane()
                .tabItem { Label("일반", systemImage: "gearshape") }
            PluginSettingsPane(catalog: catalog)
                .tabItem { Label("플러그인", systemImage: "puzzlepiece.extension") }
            PermissionSettingsPane()
                .tabItem { Label("권한", systemImage: "hand.raised") }
        }
        .frame(width: 560, height: 520)
    }
}
