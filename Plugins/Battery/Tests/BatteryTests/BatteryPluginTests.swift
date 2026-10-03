import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import Battery

/// Records the notch calls the plugin makes.
@MainActor
private final class RecordingHost: NotchHost {
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

/// The view drawn as the host's collapsed wings draw it, as PNG bytes.
@MainActor
private func drawing(_ view: some View) throws -> Data {
    let renderer = ImageRenderer(content: view.foregroundStyle(.white).font(.system(size: 12, weight: .medium)).environment(\.colorScheme, .dark))
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}

/// A power change slides the state glyph and the percentage out as a short live activity above
/// the always-on charging one, and no HUD: the host's HUD draws neither the percentage nor the state.
@MainActor
@Test func R10__power_change_slides_out_state_and_percentage_only_when_external_power_connects_or_disconnects() throws {
    let host = RecordingHost()
    let id = BatteryPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("battery-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "battery-tests.\(id)",
        keychainService: "battery-tests.\(id)"
    )
    let plugin = BatteryPlugin(context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage))

    plugin.update(reading(60, onPower: false, charging: false))  // first reading: nothing slides out
    plugin.update(reading(59, onPower: false, charging: false))  // percentage tick
    plugin.update(reading(59, onPower: true, charging: true))    // power connected
    plugin.update(reading(60, onPower: true, charging: true))    // tick while charging
    plugin.update(reading(60, onPower: true, charging: true, minutes: 90))  // only the time changed
    plugin.update(reading(60, onPower: false, charging: false))  // power disconnected

    #expect(host.calls == [
        "post power-change 100 2.5 seconds",
        "post charging 0 -",
        "post charging 0 -",
        "post power-change 100 2.5 seconds",
        "clear charging",
    ])

    // Plugged in: a green bolt and 59%. Unplugged: the level glyph in the host's colour and 60%.
    let changes = host.posted.filter { $0.id == "power-change" }
    try #require(changes.count == 2)
    let bolt = Image(systemName: "battery.100percent.bolt").symbolRenderingMode(.hierarchical).foregroundStyle(.green)
    #expect(try drawing(changes[0].leading) == drawing(bolt))
    #expect(try drawing(changes[0].trailing) == drawing(Text("59%").monospacedDigit()))
    #expect(try drawing(changes[1].leading) == drawing(Image(systemName: "battery.50percent").symbolRenderingMode(.hierarchical)))
    #expect(try drawing(changes[1].trailing) == drawing(Text("60%").monospacedDigit()))
    #expect(try drawing(changes[0].leading) != drawing(changes[1].leading))
    #expect(try drawing(changes[0].trailing) != drawing(changes[1].trailing))
}
