import Observation

/// The built-in display's brightness, shared by the key handling, the expanded tab and the tile.
/// Every change reads the display first, so a change made elsewhere (Control Centre, another app)
/// is the starting point of the next step.
@MainActor
@Observable
final class BrightnessModel {
    @ObservationIgnored private let brightnessControl: any BrightnessControl

    /// Nil when the built-in display's brightness cannot be changed.
    private(set) var brightness: Double?

    init(brightness: any BrightnessControl) {
        brightnessControl = brightness
    }

    /// `value` moved by `delta` steps of `1 / steps` on the step grid, kept within 0...1. A value
    /// between two steps (set with a slider) snaps to the nearest step first.
    nonisolated static func stepped(_ value: Double, by delta: Int, steps: Int) -> Double {
        let grid = Double(steps)
        return min(max(((value * grid).rounded() + Double(delta)) / grid, 0), 1)
    }

    func refresh() {
        brightness = brightnessControl.read()
    }

    /// Re-reads the brightness every half second until the calling task is cancelled. The views run
    /// it while they are on screen.
    func keepRefreshed() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Moves the brightness by `delta` steps. Nil when the brightness cannot be changed or the display
    /// refused the new value.
    func stepBrightness(by delta: Int, steps: Int) -> Double? {
        adjustBrightness { Self.stepped($0, by: delta, steps: steps) }
    }

    /// The brightness slider. A refused value snaps the slider back to what the display holds.
    func setBrightness(_ value: Double) {
        _ = adjustBrightness { _ in min(max(value, 0), 1) }
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
