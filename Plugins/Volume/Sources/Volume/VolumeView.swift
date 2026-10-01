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
                Text("이 출력 기기는 볼륨을 바꿀 수 없어요.")
                    .foregroundStyle(.secondary)
            }
        }
        .task { await model.keepRefreshed() }
    }
}

/// The home tile: the mute toggle and the volume when small, with a slider beside them when wide.
struct VolumeTile: View {
    let model: VolumeModel
    let size: TileSize

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 4) {
                if let volume = model.volume {
                    MuteToggle(model: model, volume: volume)
                    TileValue(text: percentText(volume.level))
                } else {
                    Image(systemName: "speaker.slash.fill")
                    TileValue(text: "—")
                }
                Text("볼륨")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if size != .small, let volume = model.volume {
                VolumeSlider(model: model, volume: volume)
                    .frame(width: 90)
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
}

/// The volume as a slider. A level the device refuses snaps it back.
private struct VolumeSlider: View {
    let model: VolumeModel
    let volume: VolumeState

    var body: some View {
        Slider(value: Binding(get: { volume.level }, set: { model.setVolumeLevel($0) }), in: 0...1) {
            Text("볼륨")
        }
        .labelsHidden()
    }
}

/// The speaker icon as a toggle button: on while muted.
private struct MuteToggle: View {
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

/// The plugin's page in Settings: what it does with the keys and whether it may.
struct VolumeSettingsView: View {
    let isTrusted: Bool
    let requestAccessibility: () -> Void

    var body: some View {
        LabeledContent {
            if !isTrusted {
                Button("권한 열기", action: requestAccessibility)
            }
        } label: {
            Text("볼륨·음소거 키")
            Text(isTrusted
                ? "키를 누르면 노치에 볼륨이 보여요. 이 플러그인을 끄면 키가 다시 시스템으로 가요."
                : "손쉬운 사용 권한을 켜면 키를 노치에서 처리해요. 그 전까지는 키가 원래대로 동작해요.")
        }
    }
}
