import Observation
import SwiftUI

/// The latest snapshot and the sparkline history, shared by the plugin and its expanded tab.
@MainActor
@Observable
final class SystemStatsModel {
    private(set) var snapshot: SystemSnapshot?
    private(set) var history = StatsHistory()

    func record(_ snapshot: SystemSnapshot) {
        self.snapshot = snapshot
        history.append(snapshot)
    }

    func reset() {
        snapshot = nil
        history = StatsHistory()
    }
}

/// One sparkline series per shown value. A value that is missing in a snapshot adds no point.
struct StatsHistory: Equatable {
    /// One minute at the two-second refresh.
    static let length = 30

    var cpu = History(capacity: length)
    var gpu = History(capacity: length)
    var memory = History(capacity: length)
    var diskRead = History(capacity: length)
    var diskWrite = History(capacity: length)
    var networkDown = History(capacity: length)
    var networkUp = History(capacity: length)
    var temperature = History(capacity: length)

    mutating func append(_ snapshot: SystemSnapshot) {
        if let value = snapshot.cpu?.total { cpu.append(value) }
        if let value = snapshot.gpu { gpu.append(value) }
        if let value = snapshot.memory?.usedPercent { memory.append(value) }
        if let io = snapshot.diskIO {
            diskRead.append(io.inbound)
            diskWrite.append(io.outbound)
        }
        if let network = snapshot.network {
            networkDown.append(network.inbound)
            networkUp.append(network.outbound)
        }
        if let value = snapshot.sensors?.cpuTemperature { temperature.append(value) }
    }
}

/// The six cards in a 2 x 3 grid. The tab shows them with a detail line under each sparkline; the
/// large home tile shows them compact, with the title, the value and the sparkline only. Every
/// card has a fixed width and the same lines, so the grid has a definite size: 382 x 210 pt in the
/// tab, 174 x 174 pt compact.
struct SystemStatsView: View {
    let model: SystemStatsModel
    var compact = false

    private static let spacing: CGFloat = 6
    private static let placeholder = "—"
    private static let inColor = Color.cyan
    private static let outColor = Color.orange

    var body: some View {
        let snapshot = model.snapshot
        let history = model.history
        VStack(spacing: Self.spacing) {
            HStack(spacing: Self.spacing) {
                cpuCard(snapshot?.cpu, history)
                StatCard(
                    title: "GPU",
                    value: snapshot?.gpu.map(StatFormat.percent) ?? Self.placeholder,
                    lines: [Sparkline.Line(history.gpu, color: .purple)],
                    ceiling: 100,
                    compact: compact
                ) {
                    Text("사용률")
                }
            }
            HStack(spacing: Self.spacing) {
                memoryCard(snapshot?.memory, history)
                diskCard(snapshot?.disk, snapshot?.diskIO, history)
            }
            HStack(spacing: Self.spacing) {
                networkCard(snapshot?.network, history)
                sensorCard(snapshot?.sensors, history)
            }
        }
    }

    private func cpuCard(_ cpu: CPUUsage?, _ history: StatsHistory) -> some View {
        StatCard(
            title: "CPU",
            value: cpu.map { StatFormat.percent($0.total) } ?? Self.placeholder,
            lines: [Sparkline.Line(history.cpu, color: .green)],
            ceiling: 100,
            compact: compact
        ) {
            CoreBars(cores: cpu?.cores ?? [], width: CardSize.detailWidth)
        }
    }

    private func memoryCard(_ memory: MemoryReading?, _ history: StatsHistory) -> some View {
        StatCard(
            title: "메모리",
            value: memory.map { StatFormat.memory($0.used) } ?? Self.placeholder,
            lines: [Sparkline.Line(history.memory, color: Self.pressureColor(memory?.pressure))],
            ceiling: 100,
            compact: compact
        ) {
            if let memory {
                Text("\(StatFormat.memory(memory.total)) 중 · 압력 \(memory.pressure?.title ?? Self.placeholder)")
            } else {
                Text(Self.placeholder)
            }
        }
    }

    /// The tab puts the capacity beside the free space so the rates fit on the detail line; the
    /// compact card has room for the free space only.
    private func diskCard(_ space: DiskSpace?, _ io: Throughput?, _ history: StatsHistory) -> some View {
        let value = space.map { space in
            let free = "\(StatFormat.diskSize(space.free)) 남음"
            return compact ? free : "\(StatFormat.diskSize(space.total)) 중 \(free)"
        }
        return StatCard(
            title: "디스크",
            value: value ?? Self.placeholder,
            lines: [Sparkline.Line(history.diskRead, color: Self.inColor), Sparkline.Line(history.diskWrite, color: Self.outColor)],
            ceiling: nil,
            compact: compact
        ) {
            RatePair(inLabel: "읽기", outLabel: "쓰기", rates: io, inColor: Self.inColor, outColor: Self.outColor)
        }
    }

    /// The tab shows both rates on the detail line; the compact card shows the download rate as
    /// its value.
    private func networkCard(_ network: Throughput?, _ history: StatsHistory) -> some View {
        StatCard(
            title: "네트워크",
            value: compact ? network.map { "↓ \(StatFormat.rate($0.inbound))" } ?? Self.placeholder : "",
            lines: [Sparkline.Line(history.networkDown, color: Self.inColor), Sparkline.Line(history.networkUp, color: Self.outColor)],
            ceiling: nil,
            compact: compact
        ) {
            RatePair(inLabel: "다운", outLabel: "업", rates: network, inColor: Self.inColor, outColor: Self.outColor)
        }
    }

    private func sensorCard(_ sensors: SensorReading?, _ history: StatsHistory) -> some View {
        StatCard(
            title: "센서",
            value: sensors?.cpuTemperature.map { "CPU \(StatFormat.temperature($0))" } ?? Self.placeholder,
            lines: [Sparkline.Line(history.temperature, color: .red)],
            ceiling: 110,
            compact: compact
        ) {
            if let sensors {
                Text("GPU \(sensors.gpuTemperature.map(StatFormat.temperature) ?? Self.placeholder) · 팬 \(sensors.fanText)")
            } else {
                Text("팬 \(Self.placeholder)")
            }
        }
    }

    static func pressureColor(_ pressure: MemoryPressure?) -> Color {
        switch pressure {
        case .warning: .yellow
        case .critical: .red
        case .normal, nil: .green
        }
    }
}

/// The fixed widths of a stat card.
private enum CardSize {
    static let width: CGFloat = 188
    static let padding: CGFloat = 6
    /// The width inside a full card's padding.
    static let detailWidth = width - 2 * padding
    static let compactWidth: CGFloat = 84
    static let compactPadding: CGFloat = 4
}

/// A titled card of a fixed width: the main value, a sparkline and one line of small detail text.
/// A compact card stacks the title over the value and leaves the detail out.
private struct StatCard<Detail: View>: View {
    let title: String
    let value: String
    let lines: [Sparkline.Line]
    /// Top of the chart scale; nil scales a rate chart to its largest value.
    let ceiling: Double?
    let compact: Bool
    @ViewBuilder let detail: Detail

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .minimumScaleFactor(0.7)
                    Sparkline(lines: lines, ceiling: ceiling)
                        .frame(height: 14)
                }
                .padding(CardSize.compactPadding)
                .frame(width: CardSize.compactWidth, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(value)
                            .font(.system(size: 12, weight: .semibold))
                            .monospacedDigit()
                    }
                    Sparkline(lines: lines, ceiling: ceiling)
                        .frame(height: 20)
                    detail
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        // Core bars and text lines take the same height, so every card does too.
                        .frame(height: 13, alignment: .leading)
                }
                .padding(CardSize.padding)
                .frame(width: CardSize.width, alignment: .topLeading)
            }
        }
        .lineLimit(1)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// "읽기 1.2 MB/s · 쓰기 340 KB/s" with each label in its sparkline colour.
private struct RatePair: View {
    let inLabel: String
    let outLabel: String
    let rates: Throughput?
    let inColor: Color
    let outColor: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(inLabel).foregroundStyle(inColor)
            Text(rates.map { StatFormat.rate($0.inbound) } ?? "—")
            Text(outLabel).foregroundStyle(outColor)
            Text(rates.map { StatFormat.rate($0.outbound) } ?? "—")
        }
    }
}

/// One small bar per core, filled to its usage, the bars sharing `width` between them.
private struct CoreBars: View {
    let cores: [Double]
    let width: CGFloat
    private static let spacing: CGFloat = 2

    var body: some View {
        let barWidth = cores.isEmpty ? 0 : max(1, (width - Self.spacing * CGFloat(cores.count - 1)) / CGFloat(cores.count))
        HStack(alignment: .bottom, spacing: Self.spacing) {
            ForEach(Array(cores.enumerated()), id: \.offset) { _, usage in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.12))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.green)
                        .frame(height: max(1, 12 * min(max(usage, 0), 100) / 100))
                }
                .frame(width: barWidth)
            }
        }
        .frame(height: 12)
    }
}

/// Polylines over the width it is given, oldest point on the left. Give it a frame: a shape has no
/// size of its own.
struct Sparkline: View {
    struct Line {
        let values: [Double]
        let color: Color

        init(_ history: History, color: Color) {
            values = history.values
            self.color = color
        }
    }

    /// Rate charts scale to their largest value, but never below 10 KB/s so background chatter of a
    /// few hundred bytes per second stays a flat line instead of filling the card.
    static let minimumRateCeiling = 10_000.0

    let lines: [Line]
    let ceiling: Double?

    var body: some View {
        let top = ceiling ?? max(lines.flatMap(\.values).max() ?? 0, Self.minimumRateCeiling)
        ZStack {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                SparklineShape(values: line.values, ceiling: top, capacity: StatsHistory.length)
                    .stroke(line.color, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
        }
    }
}

private struct SparklineShape: Shape {
    let values: [Double]
    let ceiling: Double
    let capacity: Int

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, ceiling > 0 else { return path }
        // A full history spans the width; a shorter one is right-aligned so new points enter at the right.
        let step = rect.width / CGFloat(max(capacity - 1, 1))
        let startX = rect.maxX - step * CGFloat(values.count - 1)
        for (index, value) in values.enumerated() {
            let fraction = min(max(value / ceiling, 0), 1)
            let point = CGPoint(x: startX + step * CGFloat(index), y: rect.maxY - rect.height * fraction)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
