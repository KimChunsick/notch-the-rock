import NotchKit
import SwiftUI

/// Shows a short status beside the collapsed notch and one tab in the expanded notch.
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
}

struct __NAME__View: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
            Text("__NAME__ 플러그인이에요.")
        }
        .padding()
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(__NAME__Plugin.self)
}
