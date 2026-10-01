import NotchKit
import SwiftUI

extension VolumeState {
    /// A crossed-out speaker when muted or silent, otherwise one to three waves by level.
    var symbol: String {
        if isMuted || level == 0 { return "speaker.slash.fill" }
        if level < 1.0 / 3 { return "speaker.wave.1.fill" }
        if level < 2.0 / 3 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// `0.5625` → `56%`.
func percentText(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

/// The expanded tab: a volume slider with a mute toggle and a brightness slider, without a margin of
/// its own (the host adds it).
struct MediaKeysView: View {
    let model: MediaKeysModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TitledGroup(title: "볼륨") {
                if let volume = model.volume {
                    HStack(spacing: 10) {
                        MuteToggle(model: model, volume: volume)
                            .frame(width: 28)
                        Slider(value: Binding(get: { volume.level }, set: { model.setVolumeLevel($0) }), in: 0...1) {
                            Text("볼륨")
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Text(percentText(volume.level))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } else {
                    Text("이 출력 기기는 볼륨을 바꿀 수 없어요.")
                        .foregroundStyle(.secondary)
                }
            }
            TitledGroup(title: "밝기") {
                if let brightness = model.brightness {
                    HStack(spacing: 10) {
                        Image(systemName: "sun.max.fill")
                            .frame(width: 28)
                        Slider(value: Binding(get: { brightness }, set: { model.setBrightness($0) }), in: 0...1) {
                            Text("밝기")
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Text(percentText(brightness))
                            .monospacedDigit()
                            .frame(width: 40, alignment: .trailing)
                    }
                } else {
                    Text("내장 화면의 밝기를 바꿀 수 없어요.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task { await model.keepRefreshed() }
    }

    private struct TitledGroup<Content: View>: View {
        let title: String
        @ViewBuilder let content: Content

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                content
            }
        }
    }
}

/// The home tile: the volume with a mute toggle when small, volume and brightness side by side when
/// wide.
struct MediaKeysTile: View {
    let model: MediaKeysModel
    let size: TileSize

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 4) {
                if let volume = model.volume {
                    MuteToggle(model: model, volume: volume)
                    TileValue(text: percentText(volume.level))
                } else {
                    Image(systemName: "speaker.slash.fill")
                    TileValue(text: "—")
                }
                TileCaption(text: "볼륨")
            }
            if size != .small {
                VStack(spacing: 4) {
                    Image(systemName: "sun.max.fill")
                    TileValue(text: model.brightness.map(percentText) ?? "—")
                    TileCaption(text: "밝기")
                }
            }
        }
        .padding(8)
        .task { await model.keepRefreshed() }
    }

    private struct TileValue: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    private struct TileCaption: View {
        let text: String

        var body: some View {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The speaker icon as a toggle button: on while muted.
private struct MuteToggle: View {
    let model: MediaKeysModel
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
