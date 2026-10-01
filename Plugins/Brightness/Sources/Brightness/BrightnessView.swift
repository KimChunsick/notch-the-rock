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

/// The home tile: the brightness when small, with a slider beside it when wide.
struct BrightnessTile: View {
    let model: BrightnessModel
    let size: TileSize

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                Text(model.brightness.map(percentText) ?? "—")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("밝기")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if size != .small, let brightness = model.brightness {
                BrightnessSlider(model: model, brightness: brightness)
                    .frame(width: 90)
            }
        }
        .padding(8)
        .task { await model.keepRefreshed() }
    }
}

/// The brightness as a slider, tinted with the gold that ends the notch's brightness bar. A value
/// the display refuses snaps it back.
private struct BrightnessSlider: View {
    static let tint = Color(red: 0.97, green: 0.73, blue: 0.28)

    let model: BrightnessModel
    let brightness: Double

    var body: some View {
        Slider(value: Binding(get: { brightness }, set: { model.setBrightness($0) }), in: 0...1) {
            Text("밝기")
        }
        .labelsHidden()
        .tint(Self.tint)
    }
}

/// The plugin's page in Settings: what it does with the keys and whether it may.
struct BrightnessSettingsView: View {
    let isTrusted: Bool
    let requestAccessibility: () -> Void

    var body: some View {
        LabeledContent {
            if !isTrusted {
                Button("권한 열기", action: requestAccessibility)
            }
        } label: {
            Text("밝기 키")
            Text(isTrusted
                ? "키를 누르면 노치에 밝기가 보여요. 이 플러그인을 끄면 키가 다시 시스템으로 가요."
                : "손쉬운 사용 권한을 켜면 키를 노치에서 처리해요. 그 전까지는 키가 원래대로 동작해요.")
        }
    }
}
