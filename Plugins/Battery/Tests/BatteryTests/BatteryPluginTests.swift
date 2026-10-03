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

/// A clock the tests move by hand; the plugin times the power-change expiry on it.
@MainActor
private final class ManualClock {
    var now = ContinuousClock.now
}

/// A monitor the test drives by hand; it counts its starts and stops.
@MainActor
private final class FakeMonitor: PowerSourceObserver {
    let report: @MainActor (PowerStatus?) -> Void
    var starts = 0
    var stops = 0

    init(report: @escaping @MainActor (PowerStatus?) -> Void) { self.report = report }
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

/// The battery the plugin reads on `activate()`, and every monitor it makes.
@MainActor
private final class FakePowerSource {
    var reading: PowerStatus?
    private(set) var monitors: [FakeMonitor] = []

    func makeMonitor(_ report: @escaping @MainActor (PowerStatus?) -> Void) -> any PowerSourceObserver {
        let monitor = FakeMonitor(report: report)
        monitors.append(monitor)
        return monitor
    }
}

@MainActor
private func makePlugin(host: RecordingHost, clock: ManualClock, power: FakePowerSource = FakePowerSource()) throws -> BatteryPlugin {
    let id = BatteryPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("battery-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "battery-tests.\(id)",
        keychainService: "battery-tests.\(id)"
    )
    let context = NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage)
    return BatteryPlugin(context: context, sampler: nil, now: { clock.now }, read: { power.reading }, makeMonitor: { power.makeMonitor($0) })
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
/// A percentage tick while it is out shows the new percentage until the same expiry.
@MainActor
@Test func R10__power_change_slides_out_state_and_percentage_only_when_external_power_connects_or_disconnects() throws {
    let host = RecordingHost()
    let clock = ManualClock()
    let plugin = try makePlugin(host: host, clock: clock)

    plugin.update(reading(60, onPower: false, charging: false))  // first reading: nothing slides out
    plugin.update(reading(59, onPower: false, charging: false))  // percentage tick
    plugin.update(reading(59, onPower: true, charging: true))    // power connected
    clock.now += .seconds(1)
    plugin.update(reading(60, onPower: true, charging: true))    // tick while charging, 1.5 s before the expiry
    plugin.update(reading(60, onPower: true, charging: true, minutes: 90))  // only the time changed
    plugin.update(reading(60, onPower: false, charging: false))  // power disconnected

    #expect(host.calls == [
        "post power-change 100 2.5 seconds",
        "post charging 0 -",
        "post power-change 100 1.5 seconds",
        "post charging 0 -",
        "post power-change 100 2.5 seconds",
        "clear charging",
    ])

    // Plugged in: a green bolt and 59%, then 60%. Unplugged: the level glyph in the host's colour and 60%.
    let changes = host.posted.filter { $0.id == "power-change" }
    try #require(changes.count == 3)
    let bolt = Image(systemName: "battery.100percent.bolt").symbolRenderingMode(.hierarchical).foregroundStyle(.green)
    #expect(try drawing(changes[0].leading) == drawing(bolt))
    #expect(try drawing(changes[0].trailing) == drawing(Text("59%").monospacedDigit()))
    #expect(try drawing(changes[1].leading) == drawing(bolt))
    #expect(try drawing(changes[1].trailing) == drawing(Text("60%").monospacedDigit()))
    #expect(try drawing(changes[2].leading) == drawing(Image(systemName: "battery.50percent").symbolRenderingMode(.hierarchical)))
    #expect(try drawing(changes[2].trailing) == drawing(Text("60%").monospacedDigit()))
    #expect(try drawing(changes[0].leading) != drawing(changes[2].leading))
    #expect(try drawing(changes[0].trailing) != drawing(changes[1].trailing))
}

/// External power connects without charging, then charging starts 1 s later: the power change
/// already out switches to the green bolt for the 1.5 s it has left, and a reading 2.5 s after it
/// slid out posts no power change, so the refresh did not extend it.
@MainActor
@Test func R10__power_change_shows_charging_that_starts_while_it_is_out_until_its_first_expiry() throws {
    let host = RecordingHost()
    let clock = ManualClock()
    let plugin = try makePlugin(host: host, clock: clock)

    plugin.update(reading(80, onPower: false, charging: false))  // on battery
    plugin.update(reading(80, onPower: true, charging: false))   // power connected, not charging yet
    clock.now += .seconds(1)
    plugin.update(reading(80, onPower: true, charging: true))    // charging starts
    clock.now += .milliseconds(1500)
    plugin.update(reading(81, onPower: true, charging: true))    // 2.5 s after the power change

    #expect(host.calls == [
        "post power-change 100 2.5 seconds",
        "post power-change 100 1.5 seconds",
        "post charging 0 -",
        "post charging 0 -",
    ])

    let changes = host.posted.filter { $0.id == "power-change" }
    try #require(changes.count == 2)
    #expect(try drawing(changes[0].leading) == drawing(Image(systemName: "battery.75percent").symbolRenderingMode(.hierarchical)))
    #expect(try drawing(changes[1].leading) == drawing(Image(systemName: "battery.100percent.bolt").symbolRenderingMode(.hierarchical).foregroundStyle(.green)))
    #expect(try drawing(changes[1].trailing) == drawing(Text("80%").monospacedDigit()))
}

/// Activating twice makes, seeds and starts one monitor; deactivating stops it and clears what the
/// plugin posted, and a second deactivate does nothing more; activating again makes a fresh monitor
/// whose first reading seeds the state as the first activation's did.
@MainActor
@Test func R64__battery_activates_once_and_starts_afresh_after_deactivate() throws {
    let host = RecordingHost()
    let power = FakePowerSource()
    power.reading = reading(46, onPower: true, charging: true)
    let plugin = try makePlugin(host: host, clock: ManualClock(), power: power)

    plugin.activate()
    plugin.activate()
    #expect(power.monitors.count == 1)
    #expect(power.monitors.map(\.starts) == [1])
    #expect(host.calls == ["post charging 0 -"])

    plugin.deactivate()
    #expect(power.monitors.map(\.stops) == [1])
    #expect(host.calls == ["post charging 0 -", "clear charging", "clear power-change"])
    plugin.deactivate()
    #expect(power.monitors.map(\.stops) == [1])
    #expect(host.calls == ["post charging 0 -", "clear charging", "clear power-change"])

    plugin.activate()
    #expect(power.monitors.count == 2)
    #expect(power.monitors.map(\.starts) == [1, 1])
    #expect(power.monitors.map(\.stops) == [1, 0])
    #expect(host.calls == ["post charging 0 -", "clear charging", "clear power-change", "post charging 0 -"])

    // The new monitor's readings reach the plugin: unplugging slides the change out.
    power.monitors[1].report(reading(46, onPower: false, charging: false))
    #expect(host.calls.suffix(2) == ["post power-change 100 2.5 seconds", "clear charging"])
    plugin.deactivate()
    #expect(power.monitors.map(\.stops) == [1, 1])
}
