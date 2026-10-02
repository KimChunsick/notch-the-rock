import SwiftUI

/// Identity and requirements of a plugin. The host reads it before creating the plugin.
public struct PluginManifest: Hashable, Sendable {
    /// Reverse-DNS identifier, e.g. `com.example.clock`. Must equal the bundle's `CFBundleIdentifier`.
    public let id: String
    /// Name shown in the home and in Settings.
    public let name: String
    /// The plugin's own version, e.g. `1.0.0`.
    public let version: String
    /// SF Symbol name used for the plugin's tab and Settings row.
    public let symbol: String
    /// NotchKit SDK version the plugin needs. Pass `NotchKitSDK.version` to record the SDK it was built with.
    public let sdkVersion: SDKVersion

    public init(id: String, name: String, version: String, symbol: String, sdkVersion: SDKVersion) {
        self.id = id
        self.name = name
        self.version = version
        self.symbol = symbol
        self.sdkVersion = sdkVersion
    }

    /// Two or more dot-separated labels of ASCII letters, digits and `-`.
    public static func isValidIdentifier(_ id: String) -> Bool {
        let labels = id.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { label in
            !label.isEmpty && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}

/// A plugin: one principal class per `.notchplugin` bundle, created by the host after `dlopen`.
///
/// Lifecycle: `init(context:)` once, then `activate()` when the user enables the plugin and
/// `deactivate()` when it is disabled or the app quits. `activate()` may run again after
/// `deactivate()`. Start long-running work in `activate()` (spawn a `Task` for async work) and stop
/// it in `deactivate()`. Plugins are never unloaded from memory once loaded.
@MainActor
public protocol NotchPlugin: AnyObject {
    static var manifest: PluginManifest { get }
    init(context: NotchContext)
    func activate()
    func deactivate()
    /// The plugin's screen in the expanded notch, or nil for none.
    var expandedTab: PluginTab? { get }
    /// The plugin's page in the Settings window, or nil for none.
    var settingsView: AnyView? { get }
    /// The plugin's tile in the home grid, or nil for none. Added in SDK 1.1; a plugin built
    /// against 1.0 reads nil.
    var tile: PluginTile? { get }
    /// The plugin's step in the first-launch onboarding, or nil for none. Added in SDK 1.3; a plugin
    /// built against an earlier SDK reads nil.
    var setup: PluginSetup? { get }
}

extension NotchPlugin {
    public var expandedTab: PluginTab? { nil }
    public var settingsView: AnyView? { nil }
    public var tile: PluginTile? { nil }
    public var setup: PluginSetup? { nil }
}

/// A plugin's screen in the expanded notch, opened from the plugin's tile or, without a tile, from
/// its row in the home list.
///
/// The view should have a definite intrinsic size (no `.infinity` frames): the host measures it and
/// sizes the expanded notch to fit, within the notch's own size and the width of the home grid.
public struct PluginTab {
    public let title: String
    /// SF Symbol name for the plugin's row in the home list.
    public let symbol: String
    public let content: AnyView

    public init<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = AnyView(content())
    }
}
