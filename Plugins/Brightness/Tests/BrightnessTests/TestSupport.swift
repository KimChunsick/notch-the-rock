import Foundation
import NotchKit
@testable import Brightness

/// Records the notch calls the plugin makes and answers attention requests with `attentionResponse`.
@MainActor
final class FakeHost: NotchHost {
    var isAccessibilityTrusted = true
    var attentionResponse: AttentionResponse = .dismissed
    /// When true, an attention request stays in the notch until its task is cancelled; the host then
    /// withdraws it and answers `.cancelled`.
    var holdsAttention = false
    var withdrawnAttentions = 0
    var huds: [String] = []
    var attentions: [String] = []
    var accessibilityRequests = 0

    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {
        huds.append("\(hud.symbol) \(hud.title) \(hud.value.map { "\($0)" } ?? "-") \(hud.detail ?? "-")")
    }
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse {
        attentions.append("\(request.title) [\(request.buttons.map(\.title).joined(separator: ", "))]")
        guard holdsAttention else { return attentionResponse }
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        withdrawnAttentions += 1
        return .cancelled
    }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    func requestAccessibility(from pluginID: String) { accessibilityRequests += 1 }
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// A context for the plugin on `host`, with storage of its own in a fresh temporary folder.
@MainActor
func makeContext(host: FakeHost) throws -> NotchContext {
    let id = BrightnessPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("brightness-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "brightness-tests.\(id)",
        keychainService: "brightness-tests.\(id)"
    )
    return NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage)
}
