import AppKit
import Observation
import SwiftUI

/// What the screen shows below the MacBook battery: the apps using the most energy and the
/// connected peripherals with a battery.
struct BatteryDetail: Equatable, Sendable {
    var apps: [AppEnergy] = []
    var peripherals: [PeripheralBattery] = []

    /// Reads both at once; a list whose source fails stays empty and its section hides.
    @Sendable static func sample() async -> BatteryDetail {
        async let apps = (try? AppEnergyReader.read()) ?? []
        async let peripherals = PeripheralReader.read()
        return await BatteryDetail(apps: apps, peripherals: peripherals)
    }
}

/// The latest reading, shared by the plugin and its expanded tab.
@MainActor
@Observable
final class BatteryModel {
    typealias Sampler = @Sendable () async -> BatteryDetail

    var status: PowerStatus?
    var detail = BatteryDetail()

    /// Nil leaves `detail` to whoever sets it (the screen's tests).
    private let sampler: Sampler?
    private let interval: Duration
    /// The sampling run that may change `detail`: the one that started last. A run whose screen
    /// closed while it waited for a sample can end after the screen opened again and a newer run
    /// started; it then leaves the newer run's lists alone.
    @ObservationIgnored private var currentRun = 0

    /// Samples every 5 s, Activity Monitor's default; each top sample itself spans 1 s of that.
    init(sampler: Sampler?, interval: Duration = .seconds(5)) {
        self.sampler = sampler
        self.interval = interval
    }

    /// Samples until the calling task is cancelled, i.e. while the screen is shown, then forgets the
    /// readings so the next visit does not open with old ones. Only the current run publishes or
    /// forgets.
    func sampleWhileShown() async {
        guard let sampler else { return }
        currentRun += 1
        let run = currentRun
        while run == currentRun, !Task.isCancelled {
            let sample = await sampler()
            guard run == currentRun, !Task.isCancelled else { break }
            detail = sample
            try? await Task.sleep(for: interval)
        }
        if run == currentRun { detail = BatteryDetail() }
    }
}

/// The expanded tab at the size of what it draws; the host adds the margin around it. Offered more
/// width (under a wider band), the symbol and the percentage, or without a reading a small dimmed
/// symbol and the message, go to either end and the rows run across it.
struct BatteryView: View {
    let model: BatteryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let status = model.status {
                HStack(spacing: 0) {
                    Image(systemName: status.glyph)
                        .font(.system(size: 44))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(status.state == .charging ? Color.green : Color.primary)
                    Spacer(minLength: 16)
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
                // A dimmed battery and the message at either end of what the screen is offered.
                HStack(spacing: 0) {
                    Image(systemName: "battery.0percent")
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 10)
                    Text("이 Mac에서 배터리를 찾지 못했어요.")
                        .foregroundStyle(.secondary)
                }
            }
            let detail = model.detail
            if !detail.apps.isEmpty {
                section("전력을 많이 쓰는 앱") {
                    ForEach(detail.apps, id: \.bundlePath) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(app.name)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if !detail.peripherals.isEmpty {
                section("주변 기기") {
                    ForEach(detail.peripherals) { device in
                        HStack(spacing: 8) {
                            Image(systemName: device.kind.symbol)
                                .frame(width: 20)
                            Text(device.name)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(device.levelsText)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .layoutPriority(1)
                        }
                    }
                }
            }
        }
        // Mounted only while the screen is shown, so sampling runs only then.
        .task { await model.sampleWhileShown() }
    }

    private func section(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            rows()
                .font(.system(size: 13))
        }
    }
}
