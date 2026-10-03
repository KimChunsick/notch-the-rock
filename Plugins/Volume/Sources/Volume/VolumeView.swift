import NotchKit
import SwiftUI

extension VolumeState {
    /// A crossed-out speaker only when the device is muted; otherwise a speaker without waves at 0
    /// (a device without a mute switch) and one to three waves by level.
    var symbol: String {
        if isMuted { return "speaker.slash.fill" }
        if level == 0 { return "speaker.fill" }
        if level < 1.0 / 3 { return "speaker.wave.1.fill" }
        if level < 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// `0.5625` → `56%`.
func percentText(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

/// The expanded tab: a volume slider with a mute toggle, without a margin of its own (the host adds
/// it).
struct VolumeView: View {
    let model: VolumeModel

    var body: some View {
        Group {
            if let volume = model.volume {
                HStack(spacing: 10) {
                    MuteToggle(model: model, volume: volume)
                        .frame(width: 28)
                    // 200 pt, or as wide as the screen is offered beyond that (under a wider band).
                    VolumeSlider(model: model, volume: volume)
                        .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity)
                    Text(percentText(volume.level))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                // A dimmed speaker and the message at either end of what the screen is offered.
                HStack(spacing: 0) {
                    Image(systemName: "speaker.slash.fill")
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 10)
                    Text("이 출력 기기는 볼륨을 바꿀 수 없어요.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.keepRefreshed() }
    }
}

/// The volume as a thin capsule track filled from the left with the notch's volume bar gradient,
/// and a round knob. A click or a drag sets the volume where the pointer is, live while dragging; a
/// value the device refuses snaps it back. Focused from the keyboard, the arrow keys step it as the
/// volume keys do, and so does VoiceOver's adjust.
struct VolumeSlider: View {
    /// Pale ice blue to a calm blue, as the notch's volume bar fills: keep it equal to
    /// `HUDBar.volume` in the app's Sources/NotchTheRock/Window/NotchRootView.swift.
    static let colors = [Color(red: 0.74, green: 0.87, blue: 1), Color(red: 0.36, green: 0.64, blue: 1)]
    static let height: CGFloat = 16
    static let thickness: CGFloat = 6
    static let knob: CGFloat = 14

    let model: VolumeModel
    let volume: VolumeState

    var body: some View {
        GeometryReader { proxy in
            // The knob's centre travels the track, which keeps half a knob from either end.
            let length = max(proxy.size.width - Self.knob, 0)
            let filled = length * volume.level
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: length, height: Self.thickness)
                    .offset(x: Self.knob / 2)
                Capsule()
                    .fill(LinearGradient(colors: Self.colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: filled, height: Self.thickness)
                    .offset(x: Self.knob / 2)
                Circle()
                    .fill(.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: filled)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                guard length > 0 else { return }
                model.setVolumeLevel(Double((drag.location.x - Self.knob / 2) / length))
            })
        }
        .frame(height: Self.height)
        // Keyboard navigation only: a focus taken by the pointer would swallow its click and drag.
        .focusable(interactions: .activate)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down: step(-1)
            case .right, .up: step(1)
            @unknown default: break
            }
        }
        .accessibilityElement()
        .accessibilityLabel("볼륨")
        .accessibilityValue(percentText(volume.level))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ delta: Int) {
        _ = model.stepVolume(by: delta, steps: VolumePlugin.steps)
    }
}

/// The speaker icon as a toggle button: on while muted.
struct MuteToggle: View {
    let model: VolumeModel
    let volume: VolumeState

    var body: some View {
        Toggle(isOn: Binding(get: { volume.isMuted }, set: { model.setMuted($0) })) {
            Image(systemName: volume.symbol)
        }
        .toggleStyle(.button)
        .disabled(!volume.canMute)
        .help("음소거")
        .accessibilityLabel("음소거")
    }
}
