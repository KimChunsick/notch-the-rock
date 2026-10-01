import Observation

/// What became of one volume or mute change.
enum VolumeAdjustment: Equatable {
    /// The device took the change and holds this state.
    case changed(VolumeState)
    /// The device refused a write. Its state read again afterwards, nil when it can no longer be read.
    case refused(VolumeState?)
    /// There is no default output whose volume can be set, or the change needs a mute switch the
    /// device does not have.
    case unavailable
}

/// The output volume and display brightness, shared by the key handling, the expanded tab and the
/// tile. Every change reads the device first, so a change made elsewhere (the menu bar, another
/// app) is the starting point of the next step.
@MainActor
@Observable
final class MediaKeysModel {
    @ObservationIgnored private let volumeControl: any VolumeControl
    @ObservationIgnored private let brightnessControl: any BrightnessControl

    /// Nil when the default output device's volume cannot be set.
    private(set) var volume: VolumeState?
    /// Nil when the built-in display's brightness cannot be changed.
    private(set) var brightness: Double?

    init(volume: any VolumeControl, brightness: any BrightnessControl) {
        volumeControl = volume
        brightnessControl = brightness
    }

    /// `value` moved by `delta` steps of `1 / steps` on the step grid, kept within 0...1. A value
    /// between two steps (set with a slider) snaps to the nearest step first.
    nonisolated static func stepped(_ value: Double, by delta: Int, steps: Int) -> Double {
        let grid = Double(steps)
        return min(max(((value * grid).rounded() + Double(delta)) / grid, 0), 1)
    }

    func refresh() {
        volume = volumeControl.defaultOutputDevice().flatMap { volumeControl.read($0) }
        brightness = brightnessControl.read()
    }

    /// Re-reads both values every half second until the calling task is cancelled. The views run it
    /// while they are on screen.
    func keepRefreshed() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Moves the volume by `delta` steps; a step up also unmutes.
    func stepVolume(by delta: Int, steps: Int) -> VolumeAdjustment {
        adjustVolume { state in
            var state = state
            state.level = Self.stepped(state.level, by: delta, steps: steps)
            if delta > 0, state.canMute {
                state.isMuted = false
            }
            return state
        }
    }

    /// Flips the mute switch.
    func toggleMute() -> VolumeAdjustment {
        adjustVolume { state in
            guard state.canMute else { return nil }
            var state = state
            state.isMuted.toggle()
            return state
        }
    }

    /// Moves the brightness by `delta` steps. Nil when the brightness cannot be changed or the display
    /// refused the new value.
    func stepBrightness(by delta: Int, steps: Int) -> Double? {
        adjustBrightness { Self.stepped($0, by: delta, steps: steps) }
    }

    /// The volume slider. A refused value snaps the slider back to what the device holds.
    func setVolumeLevel(_ level: Double) {
        _ = adjustVolume { state in
            var state = state
            state.level = min(max(level, 0), 1)
            return state
        }
    }

    /// The mute toggle.
    func setMuted(_ muted: Bool) {
        _ = adjustVolume { state in
            guard state.canMute else { return nil }
            var state = state
            state.isMuted = muted
            return state
        }
    }

    /// The brightness slider. A refused value snaps the slider back to what the display holds.
    func setBrightness(_ value: Double) {
        _ = adjustBrightness { _ in min(max(value, 0), 1) }
    }

    /// One read, change and write of the default output. The device is looked up once, so the read
    /// and every write hit the same device even when the default output switches meanwhile; a device
    /// that disappears refuses the write. `change` gives the new state, or nil when the device cannot
    /// make it. Only what changes is written, the mute switch first: when the level is refused after
    /// an unmute, the key goes to the system, which then makes the step on the unmuted device. After
    /// a refused write the device is read again, so `volume` shows what it holds.
    private func adjustVolume(_ change: (VolumeState) -> VolumeState?) -> VolumeAdjustment {
        guard let device = volumeControl.defaultOutputDevice(), let current = volumeControl.read(device) else {
            volume = nil
            return .unavailable
        }
        guard let target = change(current) else {
            volume = current
            return .unavailable
        }
        let written = (target.isMuted == current.isMuted || volumeControl.setMuted(target.isMuted, on: device))
            && (target.level == current.level || volumeControl.setLevel(target.level, on: device))
        guard written else {
            let actual = volumeControl.read(device)
            volume = actual
            return .refused(actual)
        }
        volume = target
        return .changed(target)
    }

    /// One read, change and write of the built-in display's brightness. After a refused write the
    /// display is read again, so `brightness` shows what it holds. Nil when nothing changed.
    private func adjustBrightness(_ change: (Double) -> Double) -> Double? {
        guard let current = brightnessControl.read() else {
            brightness = nil
            return nil
        }
        let target = change(current)
        guard target == current || brightnessControl.set(target) else {
            brightness = brightnessControl.read()
            return nil
        }
        brightness = target
        return target
    }
}
