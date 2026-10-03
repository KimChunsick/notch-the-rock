import Observation

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
