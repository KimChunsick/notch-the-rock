import NotchKit
import SwiftUI

/// The home tile. It draws the model the tab draws, so it adds no reading of its own. Small: CPU
/// usage with its sparkline. Wide: CPU, memory and CPU temperature, a row each with a sparkline.
/// Large: the tab's six cards, compact.
struct SystemStatsTile: View {
    let model: SystemStatsModel
    let size: TileSize

    /// One row of the wide tile; the small tile shows the first.
    struct Row {
        let title: String
        let value: String
        let line: Sparkline.Line
        /// Top of the chart scale.
        let ceiling: Double
    }

    /// CPU, memory and CPU temperature from the latest snapshot, "—" for what is not read yet.
    var rows: [Row] {
        let snapshot = model.snapshot
        let history = model.history
        let pressure = snapshot?.memory?.pressure
        return [
            Row(title: "CPU", value: snapshot?.cpu.map { StatFormat.percent($0.total) } ?? "—",
                line: Sparkline.Line(history.cpu, color: .green), ceiling: 100),
            Row(title: "메모리", value: snapshot?.memory.map { StatFormat.memory($0.used) } ?? "—",
                line: Sparkline.Line(history.memory, color: SystemStatsView.pressureColor(pressure)), ceiling: 100),
            Row(title: "온도", value: snapshot?.sensors?.cpuTemperature.map(StatFormat.temperature) ?? "—",
                line: Sparkline.Line(history.temperature, color: .red), ceiling: 110),
        ]
    }

    var body: some View {
        switch size {
        case .small:
            small
        case .wide:
            wide
        case .large:
            SystemStatsView(model: model, compact: true)
                .padding(7)
        @unknown default:
            small
        }
    }

    private var small: some View {
        let cpu = rows[0]
        return VStack(alignment: .leading, spacing: 4) {
            Text(cpu.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(cpu.value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Sparkline(lines: [cpu.line], ceiling: cpu.ceiling)
                .frame(width: 66, height: 16)
        }
        .lineLimit(1)
        .padding(10)
    }

    private var wide: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.title) { row in
                HStack(spacing: 6) {
                    Text(row.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .leading)
                    Text(row.value)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                        .frame(width: 52, alignment: .leading)
                    Sparkline(lines: [row.line], ceiling: row.ceiling)
                        .frame(width: 64, height: 14)
                }
            }
        }
        .lineLimit(1)
        .padding(10)
    }
}
