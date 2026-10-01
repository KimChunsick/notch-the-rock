import AppKit
import Observation
import SwiftUI

/// The Settings window, opened by the notch's gear buttons, its 설정… menu item and a reopen of the
/// running app. One window is kept and brought to the front again on every open.
@MainActor
final class SettingsWindowController {
    private let catalog: PluginCatalog
    private let selection = SettingsSelection()
    private var window: NSWindow?

    init(catalog: PluginCatalog) {
        self.catalog = catalog
    }

    /// Shows the window; for a plugin's id, on the 플러그인 tab at that plugin's page.
    func show(pluginID: String? = nil) {
        if let pluginID { selection.reveal(pluginID: pluginID) }
        let window = window ?? makeWindow()
        self.window = window
        window.showInFront()
    }

    func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(catalog: catalog, selection: selection)))
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

/// The Settings window's tab, and the plugin whose page the 플러그인 tab scrolls to.
@MainActor
@Observable
final class SettingsSelection {
    enum Tab: Hashable {
        case general
        case plugins
        case permissions
    }

    /// One request to show a plugin's page. Each is new, so asking again for the same plugin after
    /// scrolling away scrolls back to it.
    struct Reveal: Equatable {
        let pluginID: String
        let serial: Int

        /// The plugin's record, matched by identifier as the host keys plugins (`PluginKey`).
        func record(in records: [PluginRecord]) -> PluginRecord.ID? {
            records.first { $0.key == PluginKey(pluginID) }?.id
        }
    }

    var tab: Tab = .general
    private(set) var revealed: Reveal?

    func reveal(pluginID: String) {
        tab = .plugins
        revealed = Reveal(pluginID: pluginID, serial: (revealed?.serial ?? 0) + 1)
    }
}

struct SettingsView: View {
    let catalog: PluginCatalog
    @Bindable var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettingsPane()
                .tabItem { Label("일반", systemImage: "gearshape") }
                .tag(SettingsSelection.Tab.general)
            PluginSettingsPane(catalog: catalog, revealed: selection.revealed)
                .tabItem { Label("플러그인", systemImage: "puzzlepiece.extension") }
                .tag(SettingsSelection.Tab.plugins)
            PermissionSettingsPane()
                .tabItem { Label("권한", systemImage: "hand.raised") }
                .tag(SettingsSelection.Tab.permissions)
        }
        .frame(width: 560, height: 520)
    }
}
