import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import Volume

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

/// Output devices by id, the default output being `defaultDevice`. A device without a state is gone
/// or has no volume the app can set.
@MainActor
private final class FakeVolume: VolumeControl {
    var devices: [AudioObjectID: VolumeState] = [:]
    var defaultDevice: AudioObjectID = 1
    var refusesLevel = false
    var refusesMute = false
    /// Runs once right after the next read, between an adjustment's read and its writes.
    var afterRead: (@MainActor () -> Void)?
    /// The device of every read and write, in order.
    var touched: [AudioObjectID] = []
    /// Every write asked of a device, the refused ones included.
    var writes: [String] = []

    init(_ state: VolumeState?) { self.state = state }

    /// The default output's state.
    var state: VolumeState? {
        get { devices[defaultDevice] }
        set { devices[defaultDevice] = newValue }
    }

    func defaultOutputDevice() -> AudioObjectID? { defaultDevice }

    func read(_ device: AudioObjectID) -> VolumeState? {
        touched.append(device)
        let state = devices[device]
        let hook = afterRead
        afterRead = nil
        hook?()
        return state
    }

    func setLevel(_ level: Double, on device: AudioObjectID) -> Bool {
        touched.append(device)
        writes.append("level \(level)")
        guard !refusesLevel, devices[device] != nil else { return false }
        devices[device]?.level = level
        return true
    }

    func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool {
        touched.append(device)
        writes.append("mute \(muted)")
        guard !refusesMute, devices[device] != nil else { return false }
        devices[device]?.isMuted = muted
        return true
    }
}

@MainActor
private final class FakeTap: KeyEventTap {
    var refuses = false
    private(set) var handler: (@MainActor (SystemDefinedEvent) -> Bool)?
    private var interrupted: (@MainActor () -> Void)?
    private(set) var installs = 0
    private(set) var removals = 0
    var isInstalled: Bool { handler != nil }

    func install(
        handler: @escaping @MainActor (SystemDefinedEvent) -> Bool,
        interrupted: @escaping @MainActor () -> Void
    ) -> Bool {
        installs += 1
        guard !refuses else { return false }
        self.handler = handler
        self.interrupted = interrupted
        return true
    }

    func remove() {
        guard handler != nil else { return }
        removals += 1
        handler = nil
        interrupted = nil
    }

    /// The system turned the tap off for a while and on again: whatever happened meanwhile went to
    /// the system.
    func interrupt() {
        interrupted?()
    }
}

private let down = 0xA
private let up = 0xB

@MainActor
private final class Harness {
    let host = FakeHost()
    let volume: FakeVolume
    let tap = FakeTap()
    let plugin: VolumePlugin

    init(
        volume: VolumeState? = VolumeState(level: 0.5, isMuted: false, canMute: true),
        trusted: Bool = true
    ) throws {
        self.volume = FakeVolume(volume)
        host.isAccessibilityTrusted = trusted
        let id = VolumePlugin.manifest.id
        let storage = try PluginStorage(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("volume-tests-\(UUID().uuidString)"),
            defaultsSuiteName: "volume-tests.\(id)",
            keychainService: "volume-tests.\(id)"
        )
        plugin = VolumePlugin(
            context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage),
            volume: self.volume,
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

    for key in [0, 1, 7] {
        #expect(h.send(key, down) == true, "key \(key) down")
        #expect(h.send(key, down, repeat: true) == true, "key \(key) repeat")
        #expect(h.send(key, up) == true, "key \(key) up")
    }
    // The brightness keys and the transport keys belong to other plugins.
    for other in [2, 3] + Array(16...20) {
        #expect(h.send(other, down) == false, "key \(other) down")
        #expect(h.send(other, down, repeat: true) == false, "key \(other) repeat")
        #expect(h.send(other, up) == false, "key \(other) up")
    }
    #expect(h.send(0, down, subtype: 7) == false)  // another subtype
    #expect(h.send(10, down) == false)             // eject
    #expect(h.send(0, up) == false)                // a release whose press the plugin never saw
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
@Test func R12__each_action_slides_out_its_hud() throws {
    let h = try Harness()
    h.plugin.activate()

    _ = h.send(0, down)
    _ = h.send(0, up)
    _ = h.send(1, down)
    _ = h.send(7, down)
    _ = h.send(7, down)
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
        "speaker.badge.exclamationmark.fill 볼륨 - 바꿀 수 없어요",
        "speaker.badge.exclamationmark.fill 음소거 - 바꿀 수 없어요",
        "speaker.badge.exclamationmark.fill 음소거 - 바꿀 수 없어요",
        "speaker.wave.2.fill 볼륨 0.5625 56%",
    ])
}
@MainActor
@Test func R12__a_refused_write_shows_what_the_device_holds_and_the_system_keeps_the_key() throws {
    let h = try Harness(volume: VolumeState(level: 0.5, isMuted: true, canMute: true))
    h.plugin.activate()

    // Volume up unmutes first; the level the device refuses leaves it unmuted at 0.5.
    h.volume.refusesLevel = true
    #expect(h.send(0, down) == false)
    #expect(h.send(0, up) == false)
    #expect(h.volume.state == VolumeState(level: 0.5, isMuted: false, canMute: true))
    #expect(h.plugin.model.volume == h.volume.state)

    h.volume.refusesMute = true
    #expect(h.send(7, down) == false)
    #expect(h.send(7, up) == false)
    #expect(h.volume.state?.isMuted == false)

    #expect(h.host.huds == [
        "speaker.badge.exclamationmark.fill 볼륨 0.5 바꿀 수 없어요",
        "speaker.badge.exclamationmark.fill 음소거 0.5 바꿀 수 없어요",
    ])
}
@MainActor
@Test func R12__sliders_snap_back_to_what_a_refusing_device_holds() throws {
    let h = try Harness()
    let model = h.plugin.model
    model.refresh()
    h.volume.refusesLevel = true
    h.volume.refusesMute = true

    h.volume.state?.level = 0.25  // changed elsewhere since the last refresh
    model.setVolumeLevel(0.9)
    #expect(model.volume == VolumeState(level: 0.25, isMuted: false, canMute: true))
    model.setMuted(true)
    #expect(model.volume == VolumeState(level: 0.25, isMuted: false, canMute: true))
}
@MainActor
@Test func R12__one_adjustment_reads_and_writes_the_device_it_started_with() throws {
    // Headphones (1) muted at 0.5, speakers (2) at 0.2.
    let h = try Harness(volume: VolumeState(level: 0.5, isMuted: true, canMute: true))
    let volume = h.volume
    volume.devices[2] = VolumeState(level: 0.2, isMuted: false, canMute: true)
    h.plugin.activate()

    // The speakers become the default output between the read and the writes of one key press.
    volume.afterRead = { volume.defaultDevice = 2 }
    volume.touched = []
    #expect(h.send(0, down) == true)
    #expect(volume.touched == [1, 1, 1])
    #expect(volume.devices[1] == VolumeState(level: 0.5625, isMuted: false, canMute: true))
    #expect(volume.devices[2] == VolumeState(level: 0.2, isMuted: false, canMute: true))

    // The next press starts from the new default output.
    volume.touched = []
    #expect(h.send(1, down) == true)
    #expect(volume.touched == [2, 2])
    #expect(volume.devices[2]?.level == 0.125)

    // The slider and the mute toggle as well.
    volume.afterRead = { volume.defaultDevice = 1 }
    volume.touched = []
    h.plugin.model.setVolumeLevel(0.75)
    #expect(volume.touched == [2, 2])
    #expect(volume.devices[2]?.level == 0.75)
    volume.afterRead = { volume.defaultDevice = 2 }
    volume.touched = []
    h.plugin.model.setMuted(true)
    #expect(volume.touched == [1, 1])
    #expect(volume.devices[1]?.isMuted == true)
    #expect(volume.devices[2]?.isMuted == false)

    // A device that disappears between the read and the write fails the press; the system gets it.
    volume.afterRead = {
        volume.devices[2] = nil
        volume.defaultDevice = 1
    }
    volume.touched = []
    #expect(h.send(1, down) == false)
    #expect(volume.touched == [2, 2, 2])
    #expect(volume.devices[1] == VolumeState(level: 0.5625, isMuted: true, canMute: true))
    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "speaker.wave.1.fill 볼륨 0.125 13%",
        "speaker.badge.exclamationmark.fill 볼륨 - 바꿀 수 없어요",
    ])
}
@MainActor
@Test func R12__a_handled_press_keeps_its_repeats_and_release_even_when_a_repeat_is_refused() throws {
    let h = try Harness()
    h.plugin.activate()

    // Volume up: the device refuses the first repeat and takes the next one.
    var consumed = [h.send(0, down)]
    h.volume.refusesLevel = true
    consumed.append(h.send(0, down, repeat: true))
    h.volume.refusesLevel = false
    consumed += [h.send(0, down, repeat: true), h.send(0, up)]
    // Mute: holding it changes nothing more.
    consumed += [h.send(7, down), h.send(7, down, repeat: true), h.send(7, down, repeat: true), h.send(7, up)]

    #expect(consumed == Array(repeating: true, count: 8))
    #expect(h.volume.writes == ["level 0.5625", "level 0.625", "level 0.625", "mute true"])
    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "speaker.badge.exclamationmark.fill 볼륨 0.5625 바꿀 수 없어요",
        "speaker.wave.2.fill 볼륨 0.625 63%",
        "speaker.slash.fill 음소거 0.0 -",
    ])
}
@MainActor
@Test func R12__a_press_the_system_got_keeps_its_repeats_and_release_without_writes() throws {
    let h = try Harness()
    h.plugin.activate()

    // Volume up: the device refuses the key-down and recovers before the first repeat.
    h.volume.refusesLevel = true
    var consumed = [h.send(0, down)]
    h.volume.refusesLevel = false
    consumed += [h.send(0, down, repeat: true), h.send(0, down, repeat: true), h.send(0, up)]
    // Volume down while no output device can be set, which comes back meanwhile.
    h.volume.state = nil
    consumed.append(h.send(1, down))
    h.volume.state = VolumeState(level: 0.5, isMuted: false, canMute: true)
    consumed += [h.send(1, down, repeat: true), h.send(1, up)]
    // Mute.
    h.volume.refusesMute = true
    consumed.append(h.send(7, down))
    h.volume.refusesMute = false
    consumed += [h.send(7, down, repeat: true), h.send(7, up)]

    #expect(consumed == Array(repeating: false, count: 10))
    #expect(h.volume.writes == ["level 0.5625", "mute true"])
    #expect(h.volume.state == VolumeState(level: 0.5, isMuted: false, canMute: true))
    #expect(h.host.huds == [
        "speaker.badge.exclamationmark.fill 볼륨 0.5 바꿀 수 없어요",
        "speaker.badge.exclamationmark.fill 볼륨 - 바꿀 수 없어요",
        "speaker.badge.exclamationmark.fill 음소거 0.5 바꿀 수 없어요",
    ])
}
@MainActor
@Test func R12__a_press_held_while_the_permission_arrives_stays_with_the_system() async throws {
    let h = try Harness(trusted: false)
    h.plugin.activate()

    // No tap yet: every key-down goes to the system.
    #expect([h.send(0, down), h.send(7, down)] == [nil, nil])
    h.host.isAccessibilityTrusted = true
    #expect(await waitUntil { h.tap.isInstalled })
    let rest = [
        h.send(0, down, repeat: true), h.send(0, up),
        h.send(7, down, repeat: true), h.send(7, up),
    ]
    #expect(rest == Array(repeating: false, count: 4))
    #expect(h.volume.writes.isEmpty)

    // The next press is the plugin's.
    #expect([h.send(0, down), h.send(0, down, repeat: true), h.send(0, up)] == [true, true, true])
    h.plugin.deactivate()
}
@MainActor
@Test func R12__a_key_down_after_a_missed_release_starts_a_new_press() throws {
    let h = try Harness()
    h.plugin.activate()

    // A handled press whose release never came, then a press the device refuses.
    var consumed = [h.send(0, down)]
    h.volume.refusesLevel = true
    consumed.append(h.send(0, down))
    h.volume.refusesLevel = false
    consumed += [h.send(0, down, repeat: true), h.send(0, up)]
    consumed.append(h.send(7, down))
    h.volume.refusesMute = true
    consumed.append(h.send(7, down))
    h.volume.refusesMute = false
    consumed += [h.send(7, down, repeat: true), h.send(7, up)]

    #expect(consumed == [true, false, false, false, true, false, false, false])
    #expect(h.volume.writes == ["level 0.5625", "level 0.625", "mute true", "mute false"])
}
@MainActor
@Test func R12__a_press_made_while_the_tap_was_off_stays_with_the_system() throws {
    let cases: [(key: Int, volumeWrites: [String], huds: [String])] = [
        (0, ["level 0.5625", "level 0.625", "level 0.6875"], [
            "speaker.wave.2.fill 볼륨 0.5625 56%",
            "speaker.wave.2.fill 볼륨 0.625 63%",
            "speaker.wave.3.fill 볼륨 0.6875 69%",
        ]),
        (7, ["mute true", "mute false"], [
            "speaker.slash.fill 음소거 0.0 -",
            "speaker.wave.2.fill 볼륨 0.5 50%",
        ]),
    ]
    for c in cases {
        let h = try Harness()
        h.plugin.activate()

        var consumed = [h.send(c.key, down)]
        // The tap is off while the key is released and pressed again: both reach the system.
        h.tap.interrupt()
        // Back on, the repeats and the release of that second press.
        consumed += [h.send(c.key, down, repeat: true), h.send(c.key, down, repeat: true), h.send(c.key, up)]
        // The press after it is the plugin's.
        consumed += [h.send(c.key, down), h.send(c.key, down, repeat: true), h.send(c.key, up)]

        #expect(consumed == [true, false, false, false, true, true, true], "key \(c.key)")
        #expect(h.volume.writes == c.volumeWrites, "key \(c.key)")
        #expect(h.host.huds == c.huds, "key \(c.key)")
    }
}
@MainActor
@Test func R12__an_interruption_hands_every_open_press_to_the_system() throws {
    let h = try Harness()
    h.plugin.activate()

    // Volume up and volume down held together, then mute pressed: three open presses.
    var consumed = [
        h.send(0, down), h.send(1, down),
        h.send(0, down, repeat: true), h.send(1, down, repeat: true),
        h.send(7, down),
    ]
    h.tap.interrupt()
    // The rest of all three presses goes to the system untouched.
    consumed += [
        h.send(0, down, repeat: true), h.send(1, down, repeat: true), h.send(7, down, repeat: true),
        h.send(0, up), h.send(1, up), h.send(7, up),
    ]
    // A new key-down starts a press of the plugin's.
    consumed += [h.send(0, down), h.send(0, down, repeat: true), h.send(0, up)]

    #expect(consumed == [true, true, true, true, true, false, false, false, false, false, false, true, true, true])
    #expect(h.volume.writes == ["level 0.5625", "level 0.5", "level 0.5625", "level 0.5", "mute true", "mute false", "level 0.5625", "level 0.625"])
    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "speaker.wave.2.fill 볼륨 0.5 50%",
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "speaker.wave.2.fill 볼륨 0.5 50%",
        "speaker.slash.fill 음소거 0.0 -",
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "speaker.wave.2.fill 볼륨 0.625 63%",
    ])
}
@MainActor
@Test func R12__a_press_open_across_deactivate_and_activate_stays_with_the_system() throws {
    let h = try Harness()
    h.plugin.activate()

    var consumed = [h.send(0, down), h.send(7, down)]
    h.plugin.deactivate()
    h.plugin.activate()
    consumed += [
        h.send(0, down, repeat: true), h.send(7, down, repeat: true),
        h.send(0, up), h.send(7, up),
    ]
    consumed += [h.send(1, down), h.send(1, down, repeat: true), h.send(1, up)]

    #expect(consumed == [true, true, false, false, false, false, true, true, true])
    #expect(h.volume.writes == ["level 0.5625", "mute true", "level 0.5", "level 0.4375"])
}
/// The labels of every slider under `element`, in order.
@MainActor
private func sliderLabels(in element: Any) -> [String] {
    guard let element = element as? NSAccessibilityProtocol else { return [] }
    let own = element.accessibilityRole() == .slider ? [element.accessibilityLabel() ?? ""] : []
    return own + (element.accessibilityChildren() ?? []).flatMap { sliderLabels(in: $0) }
}

@MainActor
@Test func R12__the_slider_carries_an_accessibility_label() throws {
    let h = try Harness()
    h.plugin.model.refresh()
    let tab = try #require(h.plugin.expandedTab)
    let view = NSHostingView(rootView: tab.content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = view
    // SwiftUI builds its accessibility tree only for an assistive client; this asks as one would.
    NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    #expect(sliderLabels(in: view) == ["볼륨"])
}
@MainActor
@Test func R12__without_accessibility_the_notch_guides_once_and_the_tap_follows_the_grant() async throws {
    let h = try Harness(trusted: false)
    h.host.attentionResponse = .answered(AttentionAnswer(buttonID: VolumePlugin.openAccessibilityButtonID))
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
    for h in [try Harness(), try Harness(volume: nil)] {
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
        // Wide adds the slider when the volume can be set.
        #expect(h.plugin.model.volume == nil ? wide.width == small.width : wide.width > small.width)
    }
}
/// How far the outermost ink of `view` (any channel at least 14 over black, as the end-to-end
/// capture counts it) stays from its left, right and bottom edges, drawn offscreen at its ideal
/// size. The host adds the notch's margin around a tab, so a tab's own outer padding shows here.
@MainActor
private func inkInsets(_ view: some View) throws -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    // Measured in the window, at its backing scale, as the app measures a tab.
    let size = hosting.fittingSize
    window.setContentSize(size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = try #require(rep.cgImage)
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 14 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    try #require(maxX >= 0, "no ink in \(size)")
    let scale = window.backingScaleFactor
    return (CGFloat(minX) / scale, CGFloat(width - 1 - maxX) / scale, CGFloat(height - 1 - maxY) / scale)
}

/// Expects `insets` within R15's 2 pt tolerance: a line's descent or a glyph's side bearing stays
/// inside it, outer padding or a frame larger than the ink does not.
private func expectNoOuterSpace(_ insets: (left: CGFloat, right: CGFloat, bottom: CGFloat), _ what: String) {
    print("R15 \(what): ink insets left \(insets.left) right \(insets.right) bottom \(insets.bottom) pt")
    for (side, inset) in [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)] {
        #expect(inset <= 2, "\(what): \(inset) pt of empty space at the \(side) edge")
    }
}


/// The tab is the size of what it draws, with the slider or without: the host adds the margin
/// around it.
@MainActor
@Test func R15__volume_tab_draws_to_its_edges() throws {
    for (name, h) in [("controls", try Harness()), ("unavailable", try Harness(volume: nil))] {
        h.plugin.model.refresh()
        expectNoOuterSpace(try inkInsets(try #require(h.plugin.expandedTab).content), name)
    }
}

/// The brightness keys are the brightness plugin's: the volume plugin passes every event of them on
/// untouched, so they reach the next tap (the brightness plugin's) or the system.
@MainActor
@Test func R26__brightness_keys_pass_on_untouched() throws {
    let h = try Harness()
    h.plugin.activate()

    for key in [2, 3] {
        let passed = [h.send(key, down), h.send(key, down, repeat: true), h.send(key, up)]
        #expect(passed == [false, false, false], "key \(key)")
    }
    #expect(h.volume.writes.isEmpty)
    #expect(h.host.huds.isEmpty)
    // Its own keys still show their HUD.
    #expect(h.send(0, down) == true)
    #expect(h.host.huds == ["speaker.wave.2.fill 볼륨 0.5625 56%"])
}

/// Turned off in Settings, the plugin is deactivated: its tap is gone, so no key of its own is
/// consumed and the system handles them.
@MainActor
@Test func R26__a_turned_off_volume_plugin_consumes_no_keys() throws {
    let h = try Harness()
    h.plugin.activate()
    h.plugin.deactivate()

    #expect(!h.tap.isInstalled)
    for key in [0, 1, 7] {
        #expect(h.send(key, down) == nil, "key \(key) never reaches the plugin")
    }
    #expect(h.volume.writes.isEmpty)
    #expect(h.host.huds.isEmpty)
}

/// The notch draws only the symbol and the bar, so a change the device does not take shows a
/// speaker with an exclamation badge, never one of the speakers a change that went through shows.
/// The value stays: the bar shows what the device holds.
@MainActor
@Test func R25__a_refused_change_shows_the_exclamation_speaker() throws {
    let refused = "speaker.badge.exclamationmark.fill"
    #expect(NSImage(systemSymbolName: refused, accessibilityDescription: nil) != nil)
    let succeeded = ["speaker.slash.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
    #expect(!succeeded.contains(refused))

    let h = try Harness(volume: VolumeState(level: 0.5, isMuted: true, canMute: true))
    h.plugin.activate()
    _ = h.send(1, down)                                          // taken
    h.volume.refusesLevel = true
    _ = h.send(0, down)                                          // unmuted, level refused
    h.volume.refusesMute = true
    _ = h.send(7, down)                                          // mute refused
    h.volume.state = VolumeState(level: 0.5, isMuted: false, canMute: false)
    _ = h.send(7, down)                                          // no mute switch
    h.volume.state = nil
    _ = h.send(0, down)                                          // no settable output
    h.volume.state = VolumeState(level: 0.25, isMuted: false, canMute: true)
    h.volume.refusesLevel = false
    _ = h.send(0, down)                                          // taken

    #expect(h.host.huds == [
        "speaker.slash.fill 음소거 0.0 -",
        "\(refused) 볼륨 0.4375 바꿀 수 없어요",
        "\(refused) 음소거 0.4375 바꿀 수 없어요",
        "\(refused) 음소거 - 바꿀 수 없어요",
        "\(refused) 볼륨 - 바꿀 수 없어요",
        "speaker.wave.1.fill 볼륨 0.3125 31%",
    ])
}
