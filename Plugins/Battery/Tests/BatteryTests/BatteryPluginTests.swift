import Foundation
import NotchKit
import Testing
@testable import Battery

/// Records the notch calls the plugin makes.
@MainActor
private final class RecordingHost: NotchHost {
    var calls: [String] = []

    func post(_ activity: LiveActivity, from pluginID: String) { calls.append("post \(activity.id)") }
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

private func reading(_ percentage: Int, onPower: Bool, charging: Bool, minutes: Int = 100) -> PowerStatus {
    PowerStatus(
        percentage: percentage,
        isExternalPowerConnected: onPower,
        isCharging: charging,
        isFullyCharged: false,
        timeToEmpty: onPower ? nil : .minutes(minutes),
        timeToFull: charging ? .minutes(minutes) : nil
    )
}

@MainActor
@Test func R10__hud_slides_out_only_when_external_power_connects_or_disconnects() throws {
    let host = RecordingHost()
    let id = BatteryPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("battery-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "battery-tests.\(id)",
        keychainService: "battery-tests.\(id)"
    )
    let plugin = BatteryPlugin(context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage))

    plugin.update(reading(60, onPower: false, charging: false))  // first reading: no HUD
    plugin.update(reading(59, onPower: false, charging: false))  // percentage tick
    plugin.update(reading(59, onPower: true, charging: true))    // power connected
    plugin.update(reading(60, onPower: true, charging: true))    // tick while charging
    plugin.update(reading(60, onPower: true, charging: true, minutes: 90))  // only the time changed
    plugin.update(reading(60, onPower: false, charging: false))  // power disconnected

    #expect(host.calls == [
        "hud battery.100percent.bolt 충전 중 59% 2.5 seconds",
        "post charging",
        "post charging",
        "hud battery.50percent 배터리 사용 중 60% 2.5 seconds",
        "clear charging",
    ])
}
