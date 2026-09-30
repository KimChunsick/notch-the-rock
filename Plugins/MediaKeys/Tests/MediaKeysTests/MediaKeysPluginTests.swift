import CoreGraphics
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import MediaKeys

/// Records the notch calls the plugin makes and answers attention requests with `attentionResponse`.
@MainActor
private final class FakeHost: NotchHost {
    var isAccessibilityTrusted = true
    var attentionResponse: AttentionResponse = .dismissed
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
        return attentionResponse
    }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    func requestAccessibility(from pluginID: String) { accessibilityRequests += 1 }
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

@MainActor
private final class FakeVolume: VolumeControl {
    var state: VolumeState?
    init(_ state: VolumeState?) { self.state = state }
    func read() -> VolumeState? { state }
    func setLevel(_ level: Double) { state?.level = level }
    func setMuted(_ muted: Bool) { state?.isMuted = muted }
}

@MainActor
private final class FakeBrightness: BrightnessControl {
    var value: Double?
    init(_ value: Double?) { self.value = value }
    func read() -> Double? { value }
    func set(_ value: Double) { self.value = value }
}

@MainActor
private final class FakeTap: KeyEventTap {
    var refuses = false
    private(set) var handler: (@MainActor (SystemDefinedEvent) -> Bool)?
    private(set) var installs = 0
    private(set) var removals = 0
    var isInstalled: Bool { handler != nil }

    func install(handler: @escaping @MainActor (SystemDefinedEvent) -> Bool) -> Bool {
        installs += 1
        guard !refuses else { return false }
        self.handler = handler
        return true
    }

    func remove() {
        guard handler != nil else { return }
        removals += 1
        handler = nil
    }
}

private let down = 0xA
private let up = 0xB

@MainActor
private final class Harness {
    let host = FakeHost()
    let volume: FakeVolume
    let brightness: FakeBrightness
    let tap = FakeTap()
    let plugin: MediaKeysPlugin

    init(
        volume: VolumeState? = VolumeState(level: 0.5, isMuted: false, canMute: true),
        brightness: Double? = 0.5,
        trusted: Bool = true
    ) throws {
        self.volume = FakeVolume(volume)
        self.brightness = FakeBrightness(brightness)
        host.isAccessibilityTrusted = trusted
        let id = MediaKeysPlugin.manifest.id
        let storage = try PluginStorage(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("mediakeys-tests-\(UUID().uuidString)"),
            defaultsSuiteName: "mediakeys-tests.\(id)",
            keychainService: "mediakeys-tests.\(id)"
        )
        plugin = MediaKeysPlugin(
            context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage),
            volume: self.volume,
            brightness: self.brightness,
            tap: tap,
            permissionPollInterval: .milliseconds(20)
        )
    }

    /// Sends one `NX_SYSDEFINED` event through the installed tap: true consumed, false passed on,
    /// nil when no tap is installed.
    func send(_ key: Int, _ state: Int, repeat isRepeat: Bool = false, subtype: Int = 8, flags: CGEventFlags = []) -> Bool? {
        tap.handler?(SystemDefinedEvent(subtype: subtype, data1: key << 16 | state << 8 | (isRepeat ? 1 : 0), flags: flags))
    }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

@MainActor
@Test func R12__handled_keys_are_consumed_and_every_other_event_passes() throws {
    let h = try Harness()
    h.plugin.activate()

    for key in [0, 1, 2, 3, 7] {
        #expect(h.send(key, down) == true, "key \(key) down")
        #expect(h.send(key, down, repeat: true) == true, "key \(key) repeat")
        #expect(h.send(key, up) == true, "key \(key) up")
    }
    for transport in 16...20 {
        #expect(h.send(transport, down) == false, "key \(transport) down")
        #expect(h.send(transport, up) == false, "key \(transport) up")
    }
    #expect(h.send(0, down, subtype: 7) == false)  // another subtype
    #expect(h.send(10, down) == false)             // eject
    #expect(h.send(2, up) == false)                // a release whose press the plugin never saw
}

@MainActor
@Test func R12__volume_keys_step_the_level_and_volume_up_unmutes() throws {
    let h = try Harness()
    h.plugin.activate()

    _ = h.send(0, down)
    #expect(h.volume.state?.level == 0.5625)
    _ = h.send(1, down)
    _ = h.send(1, down, repeat: true)
    #expect(h.volume.state?.level == 0.4375)
    _ = h.send(7, down)
    _ = h.send(7, down, repeat: true)  // holding mute does not unmute again
    #expect(h.volume.state?.isMuted == true)
    _ = h.send(1, down)
    #expect(h.volume.state == VolumeState(level: 0.375, isMuted: true, canMute: true))   // down keeps mute
    _ = h.send(0, down)
    #expect(h.volume.state == VolumeState(level: 0.4375, isMuted: false, canMute: true))  // up unmutes
    _ = h.send(7, down)
    _ = h.send(7, down)
    #expect(h.volume.state?.isMuted == false)
    _ = h.send(0, down, flags: [.maskAlternate, .maskShift])
    #expect(h.volume.state?.level == 0.453125)  // ⌥⇧: a quarter step

    h.volume.state?.level = 1
    _ = h.send(0, down)
    #expect(h.volume.state?.level == 1)
    h.volume.state?.level = 0
    _ = h.send(1, down)
    #expect(h.volume.state?.level == 0)
}

@MainActor
@Test func R12__brightness_keys_step_the_built_in_display() throws {
    let h = try Harness()
    h.plugin.activate()

    _ = h.send(2, down)
    #expect(h.brightness.value == 0.5625)
    _ = h.send(3, down)
    _ = h.send(3, down, repeat: true)
    #expect(h.brightness.value == 0.4375)
    h.brightness.value = 1
    _ = h.send(2, down)
    #expect(h.brightness.value == 1)
    h.brightness.value = 0
    _ = h.send(3, down)
    #expect(h.brightness.value == 0)
}

@MainActor
@Test func R12__each_action_slides_out_its_hud() throws {
    let h = try Harness(brightness: 0.25)
    h.plugin.activate()

    _ = h.send(0, down)
    _ = h.send(0, up)
    _ = h.send(1, down)
    _ = h.send(7, down)
    _ = h.send(7, down)
    _ = h.send(2, down)
    _ = h.send(3, down)
    h.volume.state?.level = 0.3
    _ = h.send(1, down)
    h.volume.state?.level = 0.9
    _ = h.send(0, down)
    h.volume.state?.level = 1.0 / 16
    _ = h.send(1, down)

    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "speaker.wave.2.fill 볼륨 0.5 50%",
        "speaker.slash.fill 음소거 0.0 -",
        "speaker.wave.2.fill 볼륨 0.5 50%",
        "sun.max.fill 밝기 0.3125 31%",
        "sun.max.fill 밝기 0.25 25%",
        "speaker.wave.1.fill 볼륨 0.25 25%",
        "speaker.wave.3.fill 볼륨 0.9375 94%",
        "speaker.slash.fill 볼륨 0.0 0%",
    ])
}

@MainActor
@Test func R12__a_device_without_settable_volume_gets_a_hud_and_the_system_keeps_the_keys() throws {
    let h = try Harness(volume: nil)
    h.plugin.activate()

    #expect(h.send(0, down) == false)
    #expect(h.send(0, up) == false)
    #expect(h.send(7, down) == false)
    #expect(h.send(7, up) == false)

    h.volume.state = VolumeState(level: 0.5, isMuted: false, canMute: false)  // no mute switch
    #expect(h.send(7, down) == false)
    #expect(h.send(7, up) == false)
    #expect(h.send(0, down) == true)

    #expect(h.host.huds == [
        "speaker.slash.fill 볼륨 - 바꿀 수 없어요",
        "speaker.slash.fill 음소거 - 바꿀 수 없어요",
        "speaker.slash.fill 음소거 - 바꿀 수 없어요",
        "speaker.wave.2.fill 볼륨 0.5625 56%",
    ])
}

@MainActor
@Test func R12__without_changeable_brightness_the_keys_pass_silently() throws {
    let h = try Harness(brightness: nil)
    h.plugin.activate()

    #expect(h.send(2, down) == false)
    #expect(h.send(2, up) == false)
    #expect(h.send(3, down) == false)
    #expect(h.send(3, up) == false)
    #expect(h.host.huds.isEmpty)
}

@MainActor
@Test func R12__without_accessibility_the_notch_guides_once_and_the_tap_follows_the_grant() async throws {
    let h = try Harness(trusted: false)
    h.host.attentionResponse = .answered(AttentionAnswer(buttonID: MediaKeysPlugin.openAccessibilityButtonID))
    h.plugin.activate()
    #expect(h.tap.installs == 0)

    // 권한 열기 asks the host for the permission.
    #expect(await waitUntil { h.host.accessibilityRequests == 1 })
    #expect(h.host.attentions == ["손쉬운 사용 권한이 필요해요 [권한 열기, 나중에]"])

    try await Task.sleep(for: .milliseconds(200))  // ten poll intervals
    #expect(h.host.attentions.count == 1)
    #expect(h.tap.installs == 0)

    h.host.isAccessibilityTrusted = true
    #expect(await waitUntil { h.tap.isInstalled })
    #expect(h.tap.installs == 1)
    #expect(h.host.attentions.count == 1)
    #expect(h.send(0, down) == true)

    h.plugin.deactivate()
    #expect(!h.tap.isInstalled)
}

@MainActor
@Test func R12__deactivate_removes_the_tap_and_stops_waiting_for_the_permission() async throws {
    let h = try Harness()
    h.plugin.activate()
    h.plugin.activate()
    #expect(h.tap.installs == 1)
    h.plugin.deactivate()
    #expect(!h.tap.isInstalled && h.tap.removals == 1)
    h.plugin.activate()
    #expect(h.tap.isInstalled && h.tap.installs == 2)
    h.plugin.deactivate()

    let waiting = try Harness(trusted: false)
    waiting.plugin.activate()
    waiting.plugin.deactivate()
    waiting.host.isAccessibilityTrusted = true
    try await Task.sleep(for: .milliseconds(200))
    #expect(waiting.tap.installs == 0)

    // A tap the system refuses despite the permission leaves the keys with the system, no retry loop.
    let refused = try Harness()
    refused.tap.refuses = true
    refused.plugin.activate()
    try await Task.sleep(for: .milliseconds(200))
    #expect(refused.tap.installs == 1)
    #expect(refused.host.attentions.isEmpty)
}

@MainActor
@Test func R12__tile_offers_small_and_wide_and_every_view_has_a_finite_size() throws {
    for h in [try Harness(), try Harness(volume: nil, brightness: nil)] {
        h.plugin.model.refresh()
        let tile = try #require(h.plugin.tile)
        #expect(tile.supportedSizes == [.small, .wide])
        let tab = try #require(h.plugin.expandedTab)

        let small = NSHostingView(rootView: tile.content(.small)).fittingSize
        let wide = NSHostingView(rootView: tile.content(.wide)).fittingSize
        let expanded = NSHostingView(rootView: tab.content).fittingSize
        for size in [small, wide, expanded] {
            #expect(size.width > 0 && size.width.isFinite && size.width < 1000, "width \(size.width)")
            #expect(size.height > 0 && size.height.isFinite && size.height < 1000, "height \(size.height)")
        }
        #expect(wide.width > small.width)
    }
}
