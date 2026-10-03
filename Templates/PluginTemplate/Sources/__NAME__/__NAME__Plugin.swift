import NotchKit
import SwiftUI

/// Shows a short status beside the collapsed notch, a small tile in the home and a screen in the
/// expanded notch that the tile opens. Its Settings page has a switch for the status.
@MainActor
public final class __NAME__Plugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "__ID__",
        name: "__NAME__",
        version: "1.0.0",
        symbol: "sparkles",
        sdkVersion: NotchKitSDK.version
    )

    /// A switch on the Settings page; its value is kept in the plugin's storage.
    static let showsStatus = PluginSettingItem.toggle(
        key: "showsStatus",
        title: "노치 옆에 보이기",
        detail: "접힌 노치 옆에 __NAME__ 상태를 보여줘요.",
        default: true
    )

    private let context: NotchContext
    /// Reads the text the status shows. Replace it with what your plugin reads (a clock, a system
    /// API); tests pass their own.
    private let readStatus: () -> String
    private var isActive = false
    private var watching: Task<Void, Never>?

    /// The app creates the plugin with this init, which wires the live dependencies.
    public convenience init(context: NotchContext) {
        self.init(context: context, readStatus: { "__NAME__" })
    }

    /// Tests create the plugin with this init and pass fakes.
    init(context: NotchContext, readStatus: @escaping () -> String) {
        self.context = context
        self.readStatus = readStatus
    }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        updateStatus()
        let changes = context.settings.changes()
        watching = Task { [weak self] in
            // A change still queued when `deactivate()` cancels this task must not post again.
            for await _ in changes where !Task.isCancelled { self?.updateStatus() }
        }
    }

    /// Stops everything `activate()` started and clears what it showed.
    public func deactivate() {
        guard isActive else { return }
        watching?.cancel()
        watching = nil
        context.clear(activityID: "status")
        isActive = false
    }

    /// What the Settings page shows: a summary, the permissions the plugin uses (none) and its
    /// settings.
    public var pluginDescription: PluginDescription? {
        PluginDescription(
            summary: "__NAME__ 상태를 노치 옆과 홈 타일에 보여줘요.",
            permissions: [],
            settings: [Self.showsStatus]
        )
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: "__NAME__", symbol: "sparkles") {
            __NAME__View()
        }
    }

    private func updateStatus() {
        guard context.settings.bool(Self.showsStatus) else {
            context.clear(activityID: "status")
            return
        }
        let status = readStatus()
        context.post(LiveActivity(id: "status") {
            Image(systemName: "sparkles")
        } trailing: {
            Text(status)
        })
    }

    /// Supported sizes, default first: add `.wide` (4x2) or `.large` (4x4) to offer more.
    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.small]) { _ in
            __NAME__TileView()
        }
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(__NAME__Plugin.self)
}
