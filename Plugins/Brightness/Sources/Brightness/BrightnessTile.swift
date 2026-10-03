import NotchKit
import SwiftUI

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
