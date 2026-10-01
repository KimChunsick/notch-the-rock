import NotchKit
import SwiftUI

/// The home tile. Small: the battery glyph and percentage. Wide: the same, with the state and the
/// time left beside them. Without a battery it says so in place of the percentage.
struct BatteryTile: View {
    let model: BatteryModel
    let size: TileSize

    var body: some View {
        let status = model.status
        Group {
            switch size {
            case .small:
                VStack(spacing: 4) {
                    glyph(status, size: 22)
                    percentage(status, size: 17)
                }
            default:
                HStack(spacing: 10) {
                    glyph(status, size: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        percentage(status, size: 20)
                        Text(status?.stateTitle ?? "배터리 없음")
                            .font(.system(size: 11, weight: .medium))
                        if let remaining = status?.remainingText {
                            Text(remaining)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
            }
        }
        .padding(10)
    }

    private func glyph(_ status: PowerStatus?, size: CGFloat) -> some View {
        Image(systemName: status?.glyph ?? "battery.0percent")
            .font(.system(size: size))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(status?.state == .charging ? Color.green : Color.primary)
    }

    private func percentage(_ status: PowerStatus?, size: CGFloat) -> some View {
        Text(status?.percentageText ?? "–")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
    }
}
