import Observation

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
        volume = volumeControl.read()
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

    /// Moves the volume by `delta` steps; a step up also unmutes. Nil when the volume cannot be set.
    func stepVolume(by delta: Int, steps: Int) -> VolumeState? {
        guard var state = volumeControl.read() else {
            volume = nil
            return nil
        }
        state.level = Self.stepped(state.level, by: delta, steps: steps)
        volumeControl.setLevel(state.level)
        if delta > 0, state.isMuted, state.canMute {
            volumeControl.setMuted(false)
            state.isMuted = false
        }
        volume = state
        return state
    }

    /// Flips the mute switch. Nil when the device has no mute switch the app can set.
    func toggleMute() -> VolumeState? {
        guard var state = volumeControl.read() else {
            volume = nil
            return nil
        }
        volume = state
        guard state.canMute else { return nil }
        state.isMuted.toggle()
        volumeControl.setMuted(state.isMuted)
        volume = state
        return state
    }

    /// Moves the brightness by `delta` steps. Nil when the brightness cannot be changed.
    func stepBrightness(by delta: Int, steps: Int) -> Double? {
        guard let current = brightnessControl.read() else {
            brightness = nil
            return nil
        }
        let value = Self.stepped(current, by: delta, steps: steps)
        brightnessControl.set(value)
        brightness = value
        return value
    }

    /// The volume slider.
    func setVolumeLevel(_ level: Double) {
        guard var state = volumeControl.read() else {
            volume = nil
            return
        }
        state.level = min(max(level, 0), 1)
        volumeControl.setLevel(state.level)
        volume = state
    }

    /// The mute toggle.
    func setMuted(_ muted: Bool) {
        guard var state = volumeControl.read() else {
            volume = nil
            return
        }
        if state.canMute {
            volumeControl.setMuted(muted)
            state.isMuted = muted
        }
        volume = state
    }

    /// The brightness slider.
    func setBrightness(_ value: Double) {
        guard brightnessControl.read() != nil else {
            brightness = nil
            return
        }
        let clamped = min(max(value, 0), 1)
        brightnessControl.set(clamped)
        brightness = clamped
    }
}
