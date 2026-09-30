import AppKit
import SwiftUI

/// The Settings window, opened by the notch's gear button and its 설정… menu item. One window is
/// kept and brought to the front again on every open.
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
        // An accessory app is not active by itself; without this the window opens behind others.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(catalog: catalog)))
        window.title = "NotchTheRock 설정"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
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
