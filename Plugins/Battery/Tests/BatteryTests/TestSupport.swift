import Foundation
import NotchKit
@testable import Battery

/// Records the notch calls the plugin makes.
@MainActor
final class RecordingHost: NotchHost {
    var calls: [String] = []
    var posted: [LiveActivity] = []

    func post(_ activity: LiveActivity, from pluginID: String) {
        calls.append("post \(activity.id) \(activity.priority) \(activity.expiresAfter.map { "\($0)" } ?? "-")")
        posted.append(activity)
    }
    func clearActivity(id: String, from pluginID: String) { calls.append("clear \(id)") }
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {
        calls.append("hud \(hud.symbol) \(hud.title) \(hud.detail ?? "-") \(duration)")
    }
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// The plugin's context on `host`, with storage in a fresh temporary directory.
@MainActor
func makeContext(host: RecordingHost = RecordingHost()) throws -> NotchContext {
    let id = BatteryPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("battery-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "battery-tests.\(id)",
        keychainService: "battery-tests.\(id)"
    )
    return NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage)
}
