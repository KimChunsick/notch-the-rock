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
        "speaker.slash.fill 음소거 0.0 -",
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
@Test(.disabled("The slider is drawn in SwiftUI; on macOS 26 its accessibility element does not appear under NSHostingView.accessibilityChildren() in the test process, even with AXEnhancedUserInterface set. VoiceOver is checked end to end."))
func R12__the_slider_carries_an_accessibility_label() throws {
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
    let succeeded = ["speaker.slash.fill", "speaker.fill", "speaker.wave.1.fill", "speaker.wave.2.fill", "speaker.wave.3.fill"]
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

/// Offered more width than its own, as the host does when the band beside the camera makes the
/// notch wider than the screen, the slider stretches and the volume stays at the right end; at its own width it keeps today's size.
@MainActor
@Test func R15__volume_screen_fills_a_wider_offer() throws {
    let h = try Harness()
    h.plugin.model.refresh()
    // Today's size.
    let cases: [(String, AnyView, CGSize)] = [("controls", try #require(h.plugin.expandedTab).content, CGSize(width: 288, height: 22))]
    for (name, view, today) in cases {
        let ideal = NSHostingView(rootView: view).fittingSize
        print("R15 volume \(name) ideal \(ideal)")
        #expect(abs(ideal.width - today.width) <= 0.5 && abs(ideal.height - today.height) <= 0.5, "\(name): the screen's own size changed: \(ideal)")
        let offered = ideal.width + 80
        let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
        #expect(abs(wide.height - ideal.height) <= 1, "\(name): wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
        let insets = try inkInsets(view.frame(width: offered))
        print("R15 volume \(name) offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
        #expect(insets.left <= 2 && insets.right <= 2, "\(name): the screen does not reach both edges of a \(offered) pt offer: \(insets)")
    }
}

/// When the output device has no volume the app can set, a dimmed speaker and the message sit at
/// either end, so the screen reaches both edges of a wider offer.
@MainActor
@Test func R15__volume_screen_without_a_volume_fills_a_wider_offer() throws {
    let h = try Harness(volume: nil)
    h.plugin.model.refresh()
    let view = try #require(h.plugin.expandedTab).content
    let ideal = NSHostingView(rootView: view).fittingSize
    print("R15 volume without a volume ideal \(ideal)")
    // Its own size: the message row is as tall as the message alone was.
    #expect(abs(ideal.width - 218) <= 0.5 && abs(ideal.height - 16) <= 0.5, "the screen's own size changed: \(ideal)")
    let offered = ideal.width + 80
    let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
    #expect(abs(wide.height - ideal.height) <= 1, "wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
    let insets = try inkInsets(view.frame(width: offered))
    print("R15 volume without a volume offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
    #expect(insets.left <= 2 && insets.right <= 2, "the screen does not reach both edges of a \(offered) pt offer: \(insets)")
}

/// A zero level alone still plays on the built-in speakers, so reaching 0 mutes as the system's keys
/// do, and the slashed speaker means the device is muted.
@MainActor
@Test func R37__stepping_down_to_zero_mutes_the_device() throws {
    let h = try Harness(volume: VolumeState(level: 1.0 / 16, isMuted: false, canMute: true))
    h.plugin.activate()

    #expect(h.send(1, down) == true)
    #expect(h.volume.writes == ["mute true", "level 0.0"])
    #expect(h.volume.state == VolumeState(level: 0, isMuted: true, canMute: true))
    #expect(h.plugin.model.volume == h.volume.state)
    #expect(h.host.huds == ["speaker.slash.fill 음소거 0.0 -"])
}
@MainActor
@Test func R37__the_slider_at_zero_mutes_and_raising_it_unmutes() throws {
    let h = try Harness()
    let model = h.plugin.model

    model.setVolumeLevel(0)
    #expect(h.volume.state == VolumeState(level: 0, isMuted: true, canMute: true))
    #expect(model.volume?.symbol == "speaker.slash.fill")
    model.setVolumeLevel(0.5)
    #expect(h.volume.state == VolumeState(level: 0.5, isMuted: false, canMute: true))
    #expect(h.volume.writes == ["mute true", "level 0.0", "mute false", "level 0.5"])
}
@MainActor
@Test func R37__a_step_up_from_zero_unmutes_at_one_step() throws {
    let h = try Harness(volume: VolumeState(level: 0, isMuted: true, canMute: true))
    h.plugin.activate()

    #expect(h.send(0, down) == true)
    #expect(h.volume.writes == ["mute false", "level 0.0625"])
    #expect(h.volume.state == VolumeState(level: 0.0625, isMuted: false, canMute: true))
    #expect(h.host.huds == ["speaker.wave.1.fill 볼륨 0.0625 6%"])
}
@MainActor
@Test func R37__a_device_without_a_mute_switch_stays_unmuted_at_zero() throws {
    #expect(NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) != nil)
    let h = try Harness(volume: VolumeState(level: 1.0 / 16, isMuted: false, canMute: false))
    h.plugin.activate()

    #expect(h.send(1, down) == true)
    #expect(h.volume.writes == ["level 0.0"])
    #expect(h.volume.state == VolumeState(level: 0, isMuted: false, canMute: false))
    // The speaker without waves: silent only as far as the device goes, not muted.
    #expect(h.plugin.model.volume?.symbol == "speaker.fill")
    #expect(h.host.huds == ["speaker.fill 볼륨 0.0 0%"])
}
@MainActor
@Test func R37__a_refused_mute_at_zero_shows_the_refusal_and_the_system_keeps_the_key() throws {
    let h = try Harness(volume: VolumeState(level: 1.0 / 16, isMuted: false, canMute: true))
    h.plugin.activate()
    h.volume.refusesMute = true

    #expect(h.send(1, down) == false)
    #expect(h.send(1, up) == false)
    #expect(h.volume.writes == ["mute true"])
    #expect(h.volume.state == VolumeState(level: 0.0625, isMuted: false, canMute: true))
    #expect(h.host.huds == ["speaker.badge.exclamationmark.fill 볼륨 0.0625 바꿀 수 없어요"])
}

/// `view` in a borderless, fully transparent window ordered in far off every screen: a pointer event
/// reaches a SwiftUI gesture only in a window on the window list. Closed by `close()`.
@MainActor
private final class Stage {
    let window: NSWindow
    let hosting: NSView

    init(_ view: some View) {
        hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    func settle() {
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    func close() { window.orderOut(nil) }

    /// The view drawn over black, as the notch shows it: RGBA bytes, rows from the top.
    func render() throws -> Render {
        settle()
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try #require(rep.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Render(pixels: pixels, width: image.width, height: image.height, scale: window.backingScaleFactor, image: try #require(context.makeImage()))
    }

    /// One pointer event at `point` in the view's coordinates (top-left origin, points).
    func send(_ type: NSEvent.EventType, at point: CGPoint) throws {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: NSPoint(x: point.x, y: hosting.bounds.height - point.y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1
        ))
        window.sendEvent(event)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
    }
}

private struct Render {
    let pixels: [UInt8]
    let width: Int
    let height: Int
    let scale: CGFloat
    let image: CGImage

    func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let i = (y * width + x) * 4
        return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
    }

    /// Writes the render as `name` when NOTCH_RENDER_DIR is set.
    func save(_ name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] else { return }
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name))
    }
}

/// The slider as `render` shows it, in pixels along its middle row: the coloured fill from the track's
/// left end up to the knob, the white knob, and the neutral rest of the track to its right end. The
/// middle row is the one with the most `isFill` pixels.
private struct SliderTrack {
    let row: Int
    let fill: ClosedRange<Int>
    let knob: ClosedRange<Int>
    let rest: ClosedRange<Int>
    let fillMean: (r: Double, g: Double, b: Double)
    let restMean: (r: Double, g: Double, b: Double)

    /// How far the knob's centre has travelled along the track, 0...1.
    var fraction: Double {
        let centre = Double(knob.lowerBound + knob.upperBound + 1) / 2
        return (centre - Double(fill.lowerBound)) / Double(rest.upperBound + 1 - fill.lowerBound)
    }

    init(_ render: Render, isFill: ((r: Int, g: Int, b: Int)) -> Bool) throws {
        let counts = (0..<render.height).map { y in (0..<render.width).filter { isFill(render.rgb($0, y)) }.count }
        let row = try #require(counts.indices.max { counts[$0] < counts[$1] }.flatMap { counts[$0] > 0 ? $0 : nil }, "no fill")
        self.row = row
        let pixel = { render.rgb($0, row) }
        let isWhite = { (p: (r: Int, g: Int, b: Int)) in min(p.r, p.g, p.b) >= 235 }
        let isNeutral = { (p: (r: Int, g: Int, b: Int)) in max(p.r, p.g, p.b) - min(p.r, p.g, p.b) <= 6 && max(p.r, p.g, p.b) >= 20 && max(p.r, p.g, p.b) < 120 }
        // A run of pixels passing `test` from the first one at or after `start` within `slack` pixels.
        func run(from start: Int, slack: Int, _ test: ((r: Int, g: Int, b: Int)) -> Bool) throws -> ClosedRange<Int> {
            let first = try #require((start..<min(start + slack + 1, render.width)).first { test(pixel($0)) }, "no run at \(start)")
            var last = first
            while last + 1 < render.width, test(pixel(last + 1)) { last += 1 }
            return first...last
        }
        let fill = try run(from: (0..<render.width).first { isFill(pixel($0)) } ?? 0, slack: 0, isFill)
        let knob = try run(from: fill.upperBound + 1, slack: 4, isWhite)
        let rest = try run(from: knob.upperBound + 1, slack: 4, isNeutral)
        (self.fill, self.knob, self.rest) = (fill, knob, rest)
        func mean(_ range: ClosedRange<Int>) -> (r: Double, g: Double, b: Double) {
            let ps = range.map(pixel), n = Double(ps.count)
            return (Double(ps.map(\.r).reduce(0, +)) / n, Double(ps.map(\.g).reduce(0, +)) / n, Double(ps.map(\.b).reduce(0, +)) / n)
        }
        fillMean = mean(fill)
        restMean = mean(rest)
    }

    /// The window point (top-left origin) `fraction` of the way along the track, on its middle row.
    func point(at fraction: Double, scale: CGFloat) -> CGPoint {
        let x = Double(fill.lowerBound) + fraction * Double(rest.upperBound + 1 - fill.lowerBound)
        return CGPoint(x: x / scale, y: (Double(row) + 0.5) / scale)
    }
}

/// R38: the volume screen's slider, and the wide tile's, draw their track with the notch volume bar's
/// blue gradient up to the knob and a neutral grey beyond it, the fill as long as the level.
@MainActor
@Test func R38__the_volume_slider_fills_with_the_volume_blue_as_far_as_the_level() throws {
    for (name, level) in [("screen", 0.25), ("screen", 0.75), ("wide tile", 0.75)] {
        let h = try Harness(volume: VolumeState(level: level, isMuted: false, canMute: true))
        h.plugin.model.refresh()
        let view = name == "screen" ? try #require(h.plugin.expandedTab).content : try #require(h.plugin.tile).content(.wide)
        let stage = Stage(view)
        defer { stage.close() }
        let render = try stage.render()
        if name == "screen", level == 0.25 { try render.save("R38-render-volume-slider-T127.png") }
        let track = try SliderTrack(render) { $0.b - $0.r >= 60 && $0.b >= 200 }
        print("R38 volume \(name) at \(level): fill \(track.fill) mean \(track.fillMean), knob \(track.knob), rest \(track.rest) mean \(track.restMean), fraction \(track.fraction)")
        #expect(track.fillMean.b - track.fillMean.r >= 80, "\(name): \(track.fillMean)")
        #expect(track.fillMean.b > track.fillMean.g, "\(name): \(track.fillMean)")
        #expect(abs(track.restMean.r - track.restMean.b) <= 4 && track.restMean.b < 100, "\(name): \(track.restMean)")
        #expect(abs(track.fraction - level) <= 0.02, "\(name): \(track.fraction)")
    }
}

/// R38: the drawn slider keeps the system slider's behaviour: a click sets the level where it lands,
/// a drag sets it live.
@MainActor
@Test func R38__clicks_and_drags_set_the_volume_through_the_slider() throws {
    let h = try Harness()
    h.plugin.model.refresh()
    let stage = Stage(try #require(h.plugin.expandedTab).content)
    defer { stage.close() }
    let render = try stage.render()
    let track = try SliderTrack(render) { $0.b - $0.r >= 60 && $0.b >= 200 }

    try stage.send(.leftMouseDown, at: track.point(at: 0.8, scale: render.scale))
    try stage.send(.leftMouseUp, at: track.point(at: 0.8, scale: render.scale))
    #expect(abs((h.volume.state?.level ?? -1) - 0.8) <= 0.01, "click: \(String(describing: h.volume.state))")

    try stage.send(.leftMouseDown, at: track.point(at: 0.8, scale: render.scale))
    try stage.send(.leftMouseDragged, at: track.point(at: 0.6, scale: render.scale))
    #expect(abs((h.volume.state?.level ?? -1) - 0.6) <= 0.01, "mid-drag: \(String(describing: h.volume.state))")
    try stage.send(.leftMouseDragged, at: track.point(at: 0.3, scale: render.scale))
    try stage.send(.leftMouseUp, at: track.point(at: 0.3, scale: render.scale))
    #expect(abs((h.volume.state?.level ?? -1) - 0.3) <= 0.01, "drag: \(String(describing: h.volume.state))")
    #expect(h.plugin.model.volume == h.volume.state)

}

/// R38 with R37: the drawn slider pulled to the left end mutes the device, and raising it unmutes.
@MainActor
@Test func R38__the_slider_pulled_to_zero_mutes_and_raised_unmutes() throws {
    let h = try Harness()
    h.plugin.model.refresh()
    let stage = Stage(try #require(h.plugin.expandedTab).content)
    defer { stage.close() }
    let render = try stage.render()
    let track = try SliderTrack(render) { $0.b - $0.r >= 60 && $0.b >= 200 }

    try stage.send(.leftMouseDown, at: track.point(at: 0.5, scale: render.scale))
    try stage.send(.leftMouseDragged, at: track.point(at: -0.1, scale: render.scale))
    try stage.send(.leftMouseUp, at: track.point(at: -0.1, scale: render.scale))
    #expect(h.volume.state == VolumeState(level: 0, isMuted: true, canMute: true))
    #expect(h.plugin.model.volume?.symbol == "speaker.slash.fill")

    try stage.send(.leftMouseDown, at: track.point(at: 0.25, scale: render.scale))
    try stage.send(.leftMouseUp, at: track.point(at: 0.25, scale: render.scale))
    #expect(h.volume.state?.isMuted == false)
    #expect(abs((h.volume.state?.level ?? -1) - 0.25) <= 0.01, "\(String(describing: h.volume.state))")
}
