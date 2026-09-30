import Foundation

// Each system source sits behind its own small protocol so the collector and the plugin can run on
// fakes in tests. The live implementations are in LiveSamplers.swift and SMC.swift.

@MainActor
protocol CPUSampler {
    /// Cumulative ticks of every core, or nil when the kernel refused the request.
    func coreTicks() -> [CoreTicks]?
}

@MainActor
protocol GPUSampler {
    /// Device utilisation in percent, or nil when there is no GPU statistic.
    func utilization() -> Double?
}

@MainActor
protocol MemorySampler {
    func memory() -> MemoryReading?
}

@MainActor
protocol DiskSampler {
    /// Capacity and free space of the boot volume.
    func space() -> DiskSpace?
    /// Cumulative bytes read (`inbound`) and written (`outbound`) by the disk under the boot volume.
    func counters() -> ByteCounters?
}

@MainActor
protocol NetworkSampler {
    /// Cumulative bytes received (`inbound`) and sent (`outbound`) per active non-loopback
    /// interface, keyed by interface name.
    func counters() -> [String: ByteCounters]
}

@MainActor
protocol SensorSampler {
    /// nil when the sensors cannot be read at all (for example no SMC connection).
    func sensors() -> SensorReading?
}

/// The samplers one activation reads from.
struct Samplers {
    var cpu: any CPUSampler
    var gpu: any GPUSampler
    var memory: any MemorySampler
    var disk: any DiskSampler
    var network: any NetworkSampler
    var sensors: any SensorSampler
}

/// Everything the tab shows for one refresh. Values that need two readings (CPU, disk and network
/// rates) are nil on the first refresh after activation.
struct SystemSnapshot: Equatable {
    var cpu: CPUUsage?
    var gpu: Double?
    var memory: MemoryReading?
    var disk: DiskSpace?
    var diskIO: Throughput?
    var network: Throughput?
    var sensors: SensorReading?
}

/// Reads the samplers and turns cumulative counters into usage and rates against the previous
/// reading. One collector lives for one activation.
@MainActor
final class StatsCollector {
    private struct Counters {
        var time: Double
        var cpu: [CoreTicks]?
        var disk: ByteCounters?
        var network: [String: ByteCounters]
    }

    private let samplers: Samplers
    private var previous: Counters?

    init(samplers: Samplers) {
        self.samplers = samplers
    }

    /// - Parameter time: a monotonic clock in seconds, e.g. `ProcessInfo.systemUptime`.
    func sample(at time: Double) -> SystemSnapshot {
        let current = Counters(
            time: time,
            cpu: samplers.cpu.coreTicks(),
            disk: samplers.disk.counters(),
            network: samplers.network.counters()
        )
        var snapshot = SystemSnapshot(
            gpu: samplers.gpu.utilization(),
            memory: samplers.memory.memory(),
            disk: samplers.disk.space(),
            sensors: samplers.sensors.sensors()
        )
        if let previous {
            let seconds = current.time - previous.time
            if let old = previous.cpu, let new = current.cpu {
                snapshot.cpu = CPUUsage(from: old, to: new)
            }
            if let old = previous.disk, let new = current.disk {
                snapshot.diskIO = Throughput(from: ["boot": old], to: ["boot": new], seconds: seconds)
            }
            snapshot.network = Throughput(from: previous.network, to: current.network, seconds: seconds)
        }
        previous = current
        return snapshot
    }
}
