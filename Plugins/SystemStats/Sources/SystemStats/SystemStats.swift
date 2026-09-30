import Foundation

/// Cumulative scheduler ticks of one core as `host_processor_info` reports them. The kernel keeps
/// them in 32-bit counters that wrap.
struct CoreTicks: Equatable, Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Busy share of each core and of all cores together over one interval, 0...100.
struct CPUUsage: Equatable, Sendable {
    var total: Double
    var cores: [Double]

    init(total: Double, cores: [Double]) {
        self.total = total
        self.cores = cores
    }

    /// Usage between two readings of the same cores; nil when the core count changed. The deltas use
    /// wrapping subtraction, so a counter that passed `UInt32.max` still gives the right interval.
    init?(from old: [CoreTicks], to new: [CoreTicks]) {
        guard old.count == new.count, !new.isEmpty else { return nil }
        var busyTicks = 0.0
        var allTicks = 0.0
        var cores: [Double] = []
        for (old, new) in zip(old, new) {
            let busy = Double(new.user &- old.user) + Double(new.system &- old.system) + Double(new.nice &- old.nice)
            let all = busy + Double(new.idle &- old.idle)
            busyTicks += busy
            allTicks += all
            cores.append(all > 0 ? busy / all * 100 : 0)
        }
        self.cores = cores
        total = allTicks > 0 ? busyTicks / allTicks * 100 : 0
    }
}

/// Cumulative byte counters of one device: read and written for a disk, received and sent for a
/// network interface.
struct ByteCounters: Equatable, Sendable {
    var inbound: UInt64
    var outbound: UInt64
}

/// Bytes per second between two readings of a counter that only grows. The counters are 64-bit and
/// cannot wrap in practice (2^64 bytes), so a smaller new value means the counter was reset (a
/// driver restarted, an interface was re-created) and the interval has no rate.
func byteRate(from old: UInt64, to new: UInt64, seconds: Double) -> Double? {
    guard seconds > 0, new >= old else { return nil }
    return Double(new - old) / seconds
}

/// Bytes per second in each direction.
struct Throughput: Equatable, Sendable {
    var inbound: Double
    var outbound: Double

    init(inbound: Double, outbound: Double) {
        self.inbound = inbound
        self.outbound = outbound
    }

    /// The rates of every device present in both readings, summed. Rates are taken per device before
    /// summing, so a device that appeared, disappeared or reset in between adds nothing for this
    /// interval instead of a spike. nil when no device is in both readings.
    init?(from old: [String: ByteCounters], to new: [String: ByteCounters], seconds: Double) {
        let devices = new.keys.filter { old[$0] != nil }
        guard seconds > 0, !devices.isEmpty else { return nil }
        inbound = 0
        outbound = 0
        for device in devices {
            let old = old[device]!, new = new[device]!
            inbound += byteRate(from: old.inbound, to: new.inbound, seconds: seconds) ?? 0
            outbound += byteRate(from: old.outbound, to: new.outbound, seconds: seconds) ?? 0
        }
    }
}

/// The kernel's memory pressure level.
enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// A value of `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    init?(level: Int32) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    var title: String {
        switch self {
        case .normal: "정상"
        case .warning: "주의"
        case .critical: "심각"
        }
    }
}

/// The page counts of `host_statistics64(HOST_VM_INFO64)` that make up used memory. `vm_stat` prints
/// the same counts as "Anonymous pages", "Pages purgeable", "Pages wired down" and "Pages occupied
/// by compressor".
struct VMPages: Equatable, Sendable {
    var anonymous: UInt64
    var purgeable: UInt64
    var wired: UInt64
    var compressor: UInt64

    /// Activity Monitor's "Memory Used": app memory (anonymous pages that are not purgeable), wired
    /// memory and the pages the compressor occupies.
    func usedBytes(pageSize: UInt64) -> UInt64 {
        let app = anonymous > purgeable ? anonymous - purgeable : 0
        return (app + wired + compressor) * pageSize
    }
}

struct MemoryReading: Equatable, Sendable {
    var used: UInt64
    var total: UInt64
    var pressure: MemoryPressure?

    var usedPercent: Double { total > 0 ? Double(used) / Double(total) * 100 : 0 }
}

/// Capacity and free space of the boot volume, as `df` reports them.
struct DiskSpace: Equatable, Sendable {
    var total: UInt64
    var free: UInt64
}

struct SensorReading: Equatable, Sendable {
    /// Average of the CPU sensors in °C, nil while none has been read.
    var cpuTemperature: Double?
    /// Average of the GPU sensors in °C.
    var gpuTemperature: Double?
    /// Speed of each fan in rpm; empty on a Mac without fans.
    var fanSpeeds: [Double]

    /// "없음" on a Mac without fans, otherwise each fan's speed, e.g. "1200 rpm · 1350 rpm".
    var fanText: String {
        fanSpeeds.isEmpty ? "없음" : fanSpeeds.map { "\(Int($0.rounded())) rpm" }.joined(separator: " · ")
    }
}

/// The last `capacity` values of one series, oldest first, for a sparkline.
struct History: Equatable, Sendable {
    let capacity: Int
    private(set) var values: [Double] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func append(_ value: Double) {
        values.append(value)
        if values.count > capacity {
            values.removeFirst(values.count - capacity)
        }
    }
}

/// Text for the tab. Numbers use "." as the decimal separator in every locale.
enum StatFormat {
    /// "42%".
    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Memory in binary units as Activity Monitor shows it: 16 GiB of RAM reads "16.0 GB".
    static func memory(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// Disk sizes in decimal units as Finder shows them: "494 GB", "57.3 GB", "2.0 TB".
    static func diskSize(_ bytes: UInt64) -> String {
        let gigabytes = Double(bytes) / 1e9
        if gigabytes >= 999.5 { return String(format: "%.1f TB", gigabytes / 1000) }
        return gigabytes >= 100 ? String(format: "%.0f GB", gigabytes) : String(format: "%.1f GB", gigabytes)
    }

    /// Rates in decimal units: "0 KB/s", "340 KB/s", "1.2 MB/s", "12 MB/s", "1.5 GB/s".
    static func rate(_ bytesPerSecond: Double) -> String {
        let kilobytes = max(bytesPerSecond, 0) / 1000
        if kilobytes < 999.5 { return String(format: "%.0f KB/s", kilobytes) }
        let megabytes = kilobytes / 1000
        if megabytes < 9.95 { return String(format: "%.1f MB/s", megabytes) }
        if megabytes < 999.5 { return String(format: "%.0f MB/s", megabytes) }
        return String(format: "%.1f GB/s", megabytes / 1000)
    }

    /// "53°C".
    static func temperature(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°C"
    }
}
