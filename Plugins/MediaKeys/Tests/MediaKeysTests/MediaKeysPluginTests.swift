import AppKit
import CoreAudio
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
private final class FakeBrightness: BrightnessControl {
    var value: Double?
    var refuses = false
    /// Every write asked of the display, the refused ones included.
    var writes: [String] = []
    init(_ value: Double?) { self.value = value }
    func read() -> Double? { value }
    func set(_ value: Double) -> Bool {
        writes.append("brightness \(value)")
        guard !refuses, self.value != nil else { return false }
        self.value = value
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

    h.brightness.refuses = true
    #expect(h.send(2, down) == false)
    #expect(h.send(2, up) == false)
    #expect(h.brightness.value == 0.5)
    #expect(h.plugin.model.brightness == 0.5)

    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5 바꿀 수 없어요",
        "speaker.wave.2.fill 음소거 0.5 바꿀 수 없어요",
    ])
}

@MainActor
@Test func R12__sliders_snap_back_to_what_a_refusing_device_holds() throws {
    let h = try Harness()
    let model = h.plugin.model
    model.refresh()
    h.volume.refusesLevel = true
    h.volume.refusesMute = true
    h.brightness.refuses = true

    h.volume.state?.level = 0.25  // changed elsewhere since the last refresh
    model.setVolumeLevel(0.9)
    #expect(model.volume == VolumeState(level: 0.25, isMuted: false, canMute: true))
    model.setMuted(true)
    #expect(model.volume == VolumeState(level: 0.25, isMuted: false, canMute: true))

    h.brightness.value = 0.75
    model.setBrightness(0.1)
    #expect(model.brightness == 0.75)
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
        "speaker.slash.fill 볼륨 - 바꿀 수 없어요",
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
    // Brightness up, refused and taken the same way.
    consumed.append(h.send(2, down))
    h.brightness.refuses = true
    consumed.append(h.send(2, down, repeat: true))
    h.brightness.refuses = false
    consumed += [h.send(2, down, repeat: true), h.send(2, up)]

    #expect(consumed == Array(repeating: true, count: 12))
    #expect(h.volume.writes == ["level 0.5625", "level 0.625", "level 0.625", "mute true"])
    #expect(h.brightness.writes == ["brightness 0.5625", "brightness 0.625", "brightness 0.625"])
    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "speaker.wave.2.fill 볼륨 0.5625 바꿀 수 없어요",
        "speaker.wave.2.fill 볼륨 0.625 63%",
        "speaker.slash.fill 음소거 0.0 -",
        "sun.max.fill 밝기 0.5625 56%",
        "sun.max.fill 밝기 0.5625 바꿀 수 없어요",
        "sun.max.fill 밝기 0.625 63%",
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
    // Brightness refused, then unavailable.
    h.brightness.refuses = true
    consumed.append(h.send(2, down))
    h.brightness.refuses = false
    consumed += [h.send(2, down, repeat: true), h.send(2, up)]
    h.brightness.value = nil
    consumed.append(h.send(3, down))
    h.brightness.value = 0.5
    consumed += [h.send(3, down, repeat: true), h.send(3, up)]

    #expect(consumed == Array(repeating: false, count: 16))
    #expect(h.volume.writes == ["level 0.5625", "mute true"])
    #expect(h.brightness.writes == ["brightness 0.5625"])
    #expect(h.volume.state == VolumeState(level: 0.5, isMuted: false, canMute: true))
    #expect(h.brightness.value == 0.5)
    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5 바꿀 수 없어요",
        "speaker.slash.fill 볼륨 - 바꿀 수 없어요",
        "speaker.wave.2.fill 음소거 0.5 바꿀 수 없어요",
    ])
}

@MainActor
@Test func R12__a_press_held_while_the_permission_arrives_stays_with_the_system() async throws {
    let h = try Harness(trusted: false)
    h.plugin.activate()

    // No tap yet: every key-down goes to the system.
    #expect([h.send(0, down), h.send(7, down), h.send(2, down)] == [nil, nil, nil])
    h.host.isAccessibilityTrusted = true
    #expect(await waitUntil { h.tap.isInstalled })
    let rest = [
        h.send(0, down, repeat: true), h.send(0, up),
        h.send(7, down, repeat: true), h.send(7, up),
        h.send(2, down, repeat: true), h.send(2, up),
    ]
    #expect(rest == Array(repeating: false, count: 6))
    #expect(h.volume.writes.isEmpty && h.brightness.writes.isEmpty)

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
    // A refused press whose release never came, then a handled one.
    h.brightness.refuses = true
    consumed.append(h.send(2, down))
    h.brightness.refuses = false
    consumed += [h.send(2, down), h.send(2, down, repeat: true), h.send(2, up)]

    #expect(consumed == [true, false, false, false, true, false, false, false, false, true, true, true])
    #expect(h.volume.writes == ["level 0.5625", "level 0.625", "mute true", "mute false"])
    #expect(h.brightness.writes == ["brightness 0.5625", "brightness 0.5625", "brightness 0.625"])
}

@MainActor
@Test func R12__a_press_made_while_the_tap_was_off_stays_with_the_system() throws {
    let cases: [(key: Int, volumeWrites: [String], brightnessWrites: [String], huds: [String])] = [
        (0, ["level 0.5625", "level 0.625", "level 0.6875"], [], [
            "speaker.wave.2.fill 볼륨 0.5625 56%",
            "speaker.wave.2.fill 볼륨 0.625 63%",
            "speaker.wave.3.fill 볼륨 0.6875 69%",
        ]),
        (7, ["mute true", "mute false"], [], [
            "speaker.slash.fill 음소거 0.0 -",
            "speaker.wave.2.fill 볼륨 0.5 50%",
        ]),
        (2, [], ["brightness 0.5625", "brightness 0.625", "brightness 0.6875"], [
            "sun.max.fill 밝기 0.5625 56%",
            "sun.max.fill 밝기 0.625 63%",
            "sun.max.fill 밝기 0.6875 69%",
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
        #expect(h.brightness.writes == c.brightnessWrites, "key \(c.key)")
        #expect(h.host.huds == c.huds, "key \(c.key)")
    }
}

@MainActor
@Test func R12__an_interruption_hands_every_open_press_to_the_system() throws {
    let h = try Harness()
    h.plugin.activate()

    // Volume up and brightness down held together, then mute pressed: three open presses.
    var consumed = [
        h.send(0, down), h.send(3, down),
        h.send(0, down, repeat: true), h.send(3, down, repeat: true),
        h.send(7, down),
    ]
    h.tap.interrupt()
    // The rest of all three presses goes to the system untouched.
    consumed += [
        h.send(0, down, repeat: true), h.send(3, down, repeat: true), h.send(7, down, repeat: true),
        h.send(0, up), h.send(3, up), h.send(7, up),
    ]
    // A new key-down starts a press of the plugin's.
    consumed += [h.send(0, down), h.send(0, down, repeat: true), h.send(0, up)]

    #expect(consumed == [true, true, true, true, true, false, false, false, false, false, false, true, true, true])
    #expect(h.volume.writes == ["level 0.5625", "level 0.625", "mute true", "mute false", "level 0.6875", "level 0.75"])
    #expect(h.brightness.writes == ["brightness 0.4375", "brightness 0.375"])
    #expect(h.host.huds == [
        "speaker.wave.2.fill 볼륨 0.5625 56%",
        "sun.max.fill 밝기 0.4375 44%",
        "speaker.wave.2.fill 볼륨 0.625 63%",
        "sun.max.fill 밝기 0.375 38%",
        "speaker.slash.fill 음소거 0.0 -",
        "speaker.wave.3.fill 볼륨 0.6875 69%",
        "speaker.wave.3.fill 볼륨 0.75 75%",
    ])
}

@MainActor
@Test func R12__a_press_open_across_deactivate_and_activate_stays_with_the_system() throws {
    let h = try Harness()
    h.plugin.activate()

    var consumed = [h.send(0, down), h.send(7, down), h.send(2, down)]
    h.plugin.deactivate()
    h.plugin.activate()
    consumed += [
        h.send(0, down, repeat: true), h.send(7, down, repeat: true), h.send(2, down, repeat: true),
        h.send(0, up), h.send(7, up), h.send(2, up),
    ]
    consumed += [h.send(1, down), h.send(1, down, repeat: true), h.send(1, up)]

    #expect(consumed == [true, true, true, false, false, false, false, false, false, true, true, true])
    #expect(h.volume.writes == ["level 0.5625", "mute true", "level 0.5", "level 0.4375"])
    #expect(h.brightness.writes == ["brightness 0.5625"])
}

/// The labels of every slider under `element`, in order.
@MainActor
private func sliderLabels(in element: Any) -> [String] {
    guard let element = element as? NSAccessibilityProtocol else { return [] }
    let own = element.accessibilityRole() == .slider ? [element.accessibilityLabel() ?? ""] : []
    return own + (element.accessibilityChildren() ?? []).flatMap { sliderLabels(in: $0) }
}

@MainActor
@Test func R12__both_sliders_carry_an_accessibility_label() throws {
    let h = try Harness()
    h.plugin.model.refresh()
    let tab = try #require(h.plugin.expandedTab)
    let view = NSHostingView(rootView: tab.content)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = view
    // SwiftUI builds its accessibility tree only for an assistive client; this asks as one would.
    NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    #expect(sliderLabels(in: view) == ["볼륨", "밝기"])
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
