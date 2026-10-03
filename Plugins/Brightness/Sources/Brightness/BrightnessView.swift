import NotchKit
import SwiftUI

/// `0.5625` → `56%`.
func percentText(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

/// The expanded tab: a brightness slider, without a margin of its own (the host adds it).
struct BrightnessView: View {
    let model: BrightnessModel

    var body: some View {
        Group {
            if let brightness = model.brightness {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max.fill")
                    // 200 pt, or as wide as the screen is offered beyond that (under a wider band).
                    BrightnessSlider(model: model, brightness: brightness)
                        .frame(minWidth: 200, idealWidth: 200, maxWidth: .infinity)
                    Text(percentText(brightness))
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                // A dimmed sun and the message at either end of what the screen is offered.
                HStack(spacing: 0) {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 10)
                    Text("내장 화면의 밝기를 바꿀 수 없어요.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.keepRefreshed() }
    }
}

/// The brightness as a thin capsule track filled from the left with the notch's brightness bar gradient,
/// and a round knob. A click or a drag sets the brightness where the pointer is, live while dragging; a
/// value the display refuses snaps it back. Focused from the keyboard, the arrow keys step it as the
/// brightness keys do, and so does VoiceOver's adjust.
struct BrightnessSlider: View {
    /// Warm beige to gold, as the notch's brightness bar fills: keep it equal to
    /// `HUDBar.warm` in the app's Sources/NotchTheRock/Window/NotchRootView.swift.
    static let colors = [Color(red: 0.95, green: 0.87, blue: 0.72), Color(red: 0.97, green: 0.73, blue: 0.28)]
    static let height: CGFloat = 16
    static let thickness: CGFloat = 6
    static let knob: CGFloat = 14

    let model: BrightnessModel
    let brightness: Double

    var body: some View {
        GeometryReader { proxy in
            // The knob's centre travels the track, which keeps half a knob from either end.
            let length = max(proxy.size.width - Self.knob, 0)
            let filled = length * brightness
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
                model.setBrightness(Double((drag.location.x - Self.knob / 2) / length))
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
        .accessibilityLabel("밝기")
        .accessibilityValue(percentText(brightness))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: step(1)
            case .decrement: step(-1)
            @unknown default: break
            }
        }
    }

    private func step(_ delta: Int) {
        _ = model.stepBrightness(by: delta, steps: BrightnessPlugin.steps)
    }
}
