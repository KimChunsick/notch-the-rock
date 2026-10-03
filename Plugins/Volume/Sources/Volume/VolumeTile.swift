import NotchKit
import SwiftUI

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
