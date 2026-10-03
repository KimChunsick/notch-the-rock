import Foundation
import NotchKit
@testable import Hello

/// Records the takeovers the plugin presents; every other host call is ignored.
@MainActor
final class RecordingHost: NotchHost {
    var takeovers: [(duration: Duration, pluginID: String)] = []

    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {
        takeovers.append((takeover.duration, pluginID))
    }
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// A context with a fresh defaults suite, so a stored toggle never leaks into another test.
@MainActor
func withContext(_ body: (NotchContext, RecordingHost) throws -> Void) throws {
    let id = HelloPlugin.manifest.id
    let suite = "HelloTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    let storage = try PluginStorage(
        directory: directory.appendingPathComponent(id),
        defaultsSuiteName: suite,
        keychainService: suite
    )
    let host = RecordingHost()
    let context = NotchContext(pluginID: id, bundleURL: directory.appendingPathComponent("Hello.notchplugin"), host: host, storage: storage)
    try body(context, host)
}
