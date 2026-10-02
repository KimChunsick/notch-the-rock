import Foundation

/// Implemented by the app. Every call carries the identifier of the plugin whose context made it.
///
/// Plugins never see the host directly; they talk to their `NotchContext`. The host arbitrates
/// what the notch shows in `NotchLayer` order: takeover > attention > HUD > live activity.
@MainActor
public protocol NotchHost: AnyObject {
    func post(_ activity: LiveActivity, from pluginID: String)
    func clearActivity(id: String, from pluginID: String)
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String)
    func present(_ takeover: Takeover, from pluginID: String)
    /// Must return exactly once. When the calling task is cancelled, withdraw the request and
    /// return `.cancelled`.
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse
    /// Expands the notch with the tab of `pluginID` selected.
    func expand(toTabOf pluginID: String)
    func collapse(from pluginID: String)
    var isAccessibilityTrusted: Bool { get }
    /// Shows the system Accessibility prompt (or the host's own guidance).
    func requestAccessibility(from pluginID: String)
    func log(_ level: LogLevel, _ message: String, from pluginID: String)
}

/// A plugin's handle to the notch. The host creates one per plugin and binds it to the plugin's
/// identifier, so a plugin can only act in its own name.
@MainActor
public final class NotchContext {
    public let pluginID: String
    /// The plugin's installed `.notchplugin` bundle.
    public let bundleURL: URL
    public let storage: PluginStorage
    /// The values of the settings the plugin declares in `pluginDescription`, kept in `storage`.
    /// (SDK 1.4)
    public let settings: PluginSettings
    public let permissions: PermissionCenter
    public let log: PluginLogger
    private let host: any NotchHost

    public init(pluginID: String, bundleURL: URL, host: any NotchHost, storage: PluginStorage) {
        self.pluginID = pluginID
        self.bundleURL = bundleURL
        self.host = host
        self.storage = storage
        self.settings = PluginSettings(defaults: storage.defaults)
        self.permissions = PermissionCenter(pluginID: pluginID, host: host)
        self.log = PluginLogger(pluginID: pluginID, host: host)
    }

    /// Shows (or replaces, by `id`) information beside the collapsed notch.
    public func post(_ activity: LiveActivity) {
        host.post(activity, from: pluginID)
    }

    public func clear(activityID: String) {
        host.clearActivity(id: activityID, from: pluginID)
    }

    /// Slides a HUD out of the notch for `duration`.
    public func showHUD(_ hud: HUD, duration: Duration = .seconds(2)) {
        host.showHUD(hud, duration: duration, from: pluginID)
    }

    /// Takes over the whole notch for the takeover's duration.
    public func present(_ takeover: Takeover) {
        host.present(takeover, from: pluginID)
    }

    /// Asks the user and waits for the single response.
    public func requestAttention(_ request: AttentionRequest) async -> AttentionResponse {
        await host.requestAttention(request, from: pluginID)
    }

    /// Expands the notch showing this plugin's tab.
    public func expand() {
        host.expand(toTabOf: pluginID)
    }

    public func collapse() {
        host.collapse(from: pluginID)
    }

    /// A SwiftPM resource bundle that `build-plugin.sh` copied into this plugin's
    /// `Contents/Resources`, or nil when there is none by that name. SwiftPM names it
    /// `<package>_<target>`: `Clock_Clock` for target `Clock` of package `Clock`. Use this instead
    /// of `Bundle.module`, which looks next to the app and in the build folder, not in the installed
    /// plugin, and stops the app when neither has the bundle.
    public func resourceBundle(named name: String) -> Bundle? {
        Bundle(url: bundleURL.appendingPathComponent("Contents/Resources/\(name).bundle"))
    }
}

/// Permissions the app holds on behalf of its plugins.
@MainActor
public struct PermissionCenter {
    let pluginID: String
    let host: any NotchHost

    /// Whether the app is trusted for Accessibility (needed for event taps and key handling).
    public var isAccessibilityTrusted: Bool { host.isAccessibilityTrusted }

    public func requestAccessibility() {
        host.requestAccessibility(from: pluginID)
    }
}

public enum LogLevel: Hashable, Sendable {
    case debug
    case info
    case error
}

/// Writes to the app's log under the plugin's identifier.
@MainActor
public struct PluginLogger {
    let pluginID: String
    let host: any NotchHost

    public func debug(_ message: String) { host.log(.debug, message, from: pluginID) }
    public func info(_ message: String) { host.log(.info, message, from: pluginID) }
    public func error(_ message: String) { host.log(.error, message, from: pluginID) }
}
