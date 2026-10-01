import Observation
import SwiftUI

/// The latest reading, shared by the plugin and its expanded tab.
@MainActor
@Observable
final class BatteryModel {
    var status: PowerStatus?
}

/// The expanded tab at the size of what it draws; the host adds the margin around it.
struct BatteryView: View {
    let model: BatteryModel

    var body: some View {
        if let status = model.status {
            HStack(spacing: 16) {
                Image(systemName: status.glyph)
                    .font(.system(size: 44))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(status.state == .charging ? Color.green : Color.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.percentageText)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(status.stateTitle)
                        .font(.headline)
                    if let remaining = status.remainingText {
                        Text(remaining)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Text("이 Mac에서 배터리를 찾지 못했어요.")
                .foregroundStyle(.secondary)
        }
    }
}
