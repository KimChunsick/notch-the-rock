import Observation

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
