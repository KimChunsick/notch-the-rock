import SwiftUI

/// Identity and requirements of a plugin. The host reads it before creating the plugin.
public struct PluginManifest: Hashable, Sendable {
    /// Reverse-DNS identifier, e.g. `com.example.clock`. Must equal the bundle's `CFBundleIdentifier`.
    public let id: String
    /// Name shown in the tab bar and in Settings.
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
    /// The tab this plugin adds to the expanded notch, or nil for none.
    var expandedTab: PluginTab? { get }
    /// The plugin's page in the Settings window, or nil for none.
    var settingsView: AnyView? { get }
}

extension NotchPlugin {
    public var expandedTab: PluginTab? { nil }
    public var settingsView: AnyView? { nil }
}

/// A tab in the expanded notch: an icon in the tab bar and the view shown when it is selected.
public struct PluginTab {
    public let title: String
    /// SF Symbol name for the tab bar.
    public let symbol: String
    public let content: AnyView

    public init<Content: View>(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = AnyView(content())
    }
}
