import AppKit
import Observation
import SwiftUI

/// The Settings window, opened by the notch's gear buttons, its 설정… menu item and a reopen of the
/// running app. One window is kept and brought to the front again on every open.
@MainActor
final class SettingsWindowController {
    private let catalog: PluginCatalog
    let selection = SettingsSelection()
    private var window: NSWindow?
    private let present: @MainActor (NSWindow) -> Void

    /// - Parameter present: brings the window to the front; tests keep it hidden.
    init(catalog: PluginCatalog, present: @escaping @MainActor (NSWindow) -> Void = { $0.showInFront() }) {
        self.catalog = catalog
        self.present = present
    }

    /// Shows the window; for a plugin's id, on the 플러그인 tab at the page of the bundle running as
    /// that plugin, or at the top of the tab when none runs.
    func show(pluginID: String? = nil) {
        if let pluginID { selection.showPlugins(revealing: catalog.runningRecord(for: pluginID)) }
        let window = window ?? makeWindow()
        self.window = window
        present(window)
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

/// The Settings window's tab, and the record whose page the 플러그인 tab scrolls to.
@MainActor
@Observable
final class SettingsSelection {
    enum Tab: Hashable {
        case general
        case plugins
        case permissions
    }

    /// One request to show a record's page. Each is new, so asking again for the same plugin after
    /// scrolling away scrolls back to it.
    struct Reveal: Equatable {
        let record: PluginRecord.ID
        let serial: Int
    }

    var tab: Tab = .general
    private(set) var revealed: Reveal?

    /// The 플러그인 tab, at `record`'s page when there is one.
    func showPlugins(revealing record: PluginRecord.ID?) {
        tab = .plugins
        revealed = record.map { Reveal(record: $0, serial: (revealed?.serial ?? 0) + 1) }
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
