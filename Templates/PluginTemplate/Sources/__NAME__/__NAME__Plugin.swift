import NotchKit
import SwiftUI

/// Shows a short status beside the collapsed notch, a small tile in the home and a screen in the
/// expanded notch that the tile opens.
@MainActor
public final class __NAME__Plugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "__ID__",
        name: "__NAME__",
        version: "1.0.0",
        symbol: "sparkles",
        sdkVersion: NotchKitSDK.version
    )

    private let context: NotchContext

    public init(context: NotchContext) {
        self.context = context
    }

    public func activate() {
        context.post(LiveActivity(id: "status") {
            Image(systemName: "sparkles")
        } trailing: {
            Text("__NAME__")
        })
    }

    public func deactivate() {
        context.clear(activityID: "status")
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: "__NAME__", symbol: "sparkles") {
            __NAME__View()
        }
    }

    /// Supported sizes, default first: add `.wide` (4x2) or `.large` (4x4) to offer more.
    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.small]) { _ in
            __NAME__TileView()
        }
    }
}

/// The expanded screen. The host sizes the notch to this view, so it keeps a size of its own:
/// no `.frame(maxWidth: .infinity)` or `maxHeight: .infinity`. The host also adds the 16 pt edge
/// margin, so the outermost view has no `.padding()` and no fixed outer frame.
struct __NAME__View: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
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
