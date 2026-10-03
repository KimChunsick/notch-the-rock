import Foundation
import NotchKit
@testable import SystemStats

/// Ignores every notch call.
@MainActor
final class SilentHost: NotchHost {
    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// The plugin's context on a silent host, with storage in a fresh temporary directory.
@MainActor
func makeContext() throws -> NotchContext {
    let id = SystemStatsPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("systemstats-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "systemstats-tests.\(id)",
        keychainService: "systemstats-tests.\(id)"
    )
    return NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: SilentHost(), storage: storage)
}
