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
    private var watching: Task<Void, Never>?

    public init(context: NotchContext) {
        self.context = context
    }

    public func activate() {
        updateStatus()
        let changes = context.settings.changes()
        watching = Task { [weak self] in
            // A change still queued when `deactivate()` cancels this task must not post again.
            for await _ in changes where !Task.isCancelled { self?.updateStatus() }
        }
    }

    public func deactivate() {
        watching?.cancel()
        watching = nil
        context.clear(activityID: "status")
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
        context.post(LiveActivity(id: "status") {
            Image(systemName: "sparkles")
        } trailing: {
            Text("__NAME__")
        })
    }

    /// Supported sizes, default first: add `.wide` (4x2) or `.large` (4x4) to offer more.
    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.small]) { _ in
            __NAME__TileView()
        }
    }
}

/// The expanded screen. The host sizes the notch to this view, so it keeps a size of its own: no
/// `maxHeight: .infinity`. Under a band wider than the view the host offers more width; the
/// `Spacer` takes it, so the symbol and the text reach the two edges and the margins stay equal.
/// The host also adds the 18 pt edge margin, so the outermost view has no `.padding()` and no fixed
/// outer frame.
struct __NAME__View: View {
    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "sparkles")
            Spacer(minLength: 12)
            Text("__NAME__ 플러그인이에요.")
        }
    }
}

/// The tile, sized by its content like the expanded screen.
struct __NAME__TileView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.title2)
            Text("__NAME__")
                .font(.caption)
        }
        .padding(8)
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(__NAME__Plugin.self)
}
