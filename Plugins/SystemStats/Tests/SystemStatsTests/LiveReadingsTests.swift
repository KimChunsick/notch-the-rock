import Darwin
import Foundation
import Testing
@testable import SystemStats

// The R11 acceptance check: at the same moment, the plugin's live samplers and the command-line
// tools must agree within the tolerances written next to each comparison. Values that are read once
// bracket the tool between two plugin readings taken right before and right after it (plugin, tool,
// plugin), so a value that moves while the tool runs still has to land between the two. The GPU
// statistic is the busy share since its previous read, so it brackets a plugin reading between two
// tool runs instead, spaced out, and judges only the attempts whose tool runs agree (see its test).
// Rates are the collector's own, read the way the plugin reads them.

/// Runs a tool to completion and returns its standard output. It is async so the wait happens off
/// the main actor, where the other tests of the package keep running.
private func run(_ path: String, _ arguments: [String] = []) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output
}

/// A tool's output with the instants, on the test's own clock, right before it was launched and
/// right after it had exited: the tool read its counters somewhere in between.
private struct ToolRun {
    var output: String
    var launched: ContinuousClock.Instant
    var exited: ContinuousClock.Instant
}

private func timedRun(_ path: String, _ arguments: [String]) async throws -> ToolRun {
    let launched = ContinuousClock.now
    let output = try await run(path, arguments)
    return ToolRun(output: output, launched: launched, exited: .now)
}

/// The range a collector rate must lie in when the collector read its counters and its clock after
/// tool run 0 and before run 1, and again after run 2 and before run 3 (`bytes[n]` is what run n
/// read). Both the bytes and the seconds of the collector's interval are bounded by the runs: at
/// least the bytes between runs 1 and 2 over the longest interval possible, at most the bytes
/// between runs 0 and 3 over the shortest. This bracket is the whole tolerance; the counters are
/// exact byte counts, so no rounding slack is added.
private func rateRange(_ runs: [ToolRun], _ bytes: [UInt64]) -> ClosedRange<Double> {
    func seconds(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Double {
        let duration = from.duration(to: to)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    let longest = seconds(runs[0].exited, runs[3].launched)
    let shortest = seconds(runs[1].launched, runs[2].exited)
    return (Double(bytes[2]) - Double(bytes[1])) / longest...(Double(bytes[3]) - Double(bytes[0])) / shortest
}

/// Whether `value` lies between `a` and `b` (in either order), widened by `slack`.
private func between<T: BinaryInteger>(_ value: T, _ a: T, _ b: T, slack: T = 0) -> Bool {
    value + slack >= min(a, b) && value <= max(a, b) + slack
}

/// Bytes read and written by the IOBlockStorageDriver whose media is `disk`, from the property list
/// `ioreg -r -c IOBlockStorageDriver -d 2 -l -a` prints.
private func diskCounters(in plist: String, disk: String) throws -> ByteCounters {
    let drivers = try #require(try PropertyListSerialization.propertyList(from: Data(plist.utf8), format: nil) as? [[String: Any]])
    let driver = try #require(drivers.first { driver in
        (driver["IORegistryEntryChildren"] as? [[String: Any]] ?? []).contains { $0["BSD Name"] as? String == disk }
    })
    let statistics = try #require(driver["Statistics"] as? [String: Any])
    return ByteCounters(
        inbound: try #require((statistics["Bytes (Read)"] as? NSNumber)?.uint64Value),
        outbound: try #require((statistics["Bytes (Write)"] as? NSNumber)?.uint64Value)
    )
}

/// Bytes received and sent per interface, from the link rows of `netstat -ib`.
private func netstatLinks(_ output: String) -> [String: ByteCounters] {
    var links: [String: ByteCounters] = [:]
    for line in output.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: " ")
        guard fields.count >= 10, fields[2].hasPrefix("<Link#"),
              let received = UInt64(fields[fields.count - 5]), let sent = UInt64(fields[fields.count - 2])
        else { continue }
        links[String(fields[0])] = ByteCounters(inbound: received, outbound: sent)
    }
    return links
}

/// Writes `mebibytes` MiB to a new file in the temporary directory, past the file cache and flushed,
/// so the boot disk's write counter grows by at least that much; then removes the file.
private func writeToDisk(mebibytes: Int) throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("systemstats-\(UUID().uuidString)").path
    let file = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
    try #require(file >= 0)
    defer {
        close(file)
        unlink(path)
    }
    _ = fcntl(file, F_NOCACHE, 1)
    let chunk = [UInt8](repeating: 0xA5, count: 1 << 20)
    for _ in 0..<mebibytes {
        try #require(write(file, chunk, chunk.count) == chunk.count)
    }
    try #require(fsync(file) == 0)
}

@MainActor
@Suite(.serialized)
struct R11LiveReadings {
    /// `top -l 2 -n 0 -s 1` prints a first sample, waits a second and prints a second sample whose CPU
    /// usage covers the time since the first. The collector reads right after top prints its first
    /// sample and again right after top exits, so both cover the same interval (about 1.1 s: the
    /// second plus top's collection time), which the window check below confirms. Top reads its ticks
    /// before it collects and prints a sample, so the collector's window is shifted later by that
    /// collection time at both edges, never widened. Six runs here during parallel builds differed by
    /// at most 0.7 points; ±5 points leaves room for a load that changes within that shift.
    @Test func R11__cpu_total_matches_top_over_the_same_interval() async throws {
        let collector = StatsCollector(samplers: .live())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "2", "-n", "0", "-s", "1"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        var lines: [String] = []
        var start: ContinuousClock.Instant?
        for try await line in pipe.fileHandleForReading.bytes.lines where line.hasPrefix("CPU usage:") {
            lines.append(line)
            if lines.count == 1 {
                _ = collector.sample()
                start = .now
            }
        }
        // The output ended: top has printed its second sample and exited.
        let usage = try #require(collector.sample().cpu)
        let window = try #require(start).duration(to: .now)
        process.waitUntilExit()

        let line = try #require(lines.count == 2 ? lines.last : nil)
        let match = try #require(line.firstMatch(of: /([\d.]+)% idle/))
        let topBusy = 100 - (Double(match.1) ?? 100)
        print("R11 top: \(line) | plugin over \(window): total \(StatFormat.percent(usage.total)), cores \(usage.cores.map(StatFormat.percent))")

        #expect(window >= .milliseconds(900) && window <= .milliseconds(1_500))
        #expect(usage.cores.count == ProcessInfo.processInfo.processorCount)
        #expect(usage.cores.allSatisfy { (0...100).contains($0) })
        #expect(abs(usage.total - topBusy) <= 5)
    }

    /// `vm_stat` page counts times its page size, fed to the same "Memory Used" formula, must land
    /// between the two plugin readings ±3% of RAM (memory moves constantly under load; 3% of 16 GB is
    /// about 500 MB). The pressure level must equal `sysctl -n kern.memorystatus_vm_pressure_level`.
    @Test func R11__memory_matches_vm_stat_and_pressure_sysctl() async throws {
        let sampler = HostMemorySampler()
        let first = try #require(sampler.memory())
        let vmStat = try await run("/usr/bin/vm_stat")
        let level = try await run("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"])
        let second = try #require(sampler.memory())

        func pages(_ label: String) throws -> UInt64 {
            let line = try #require(vmStat.split(separator: "\n").first { $0.hasPrefix(label + ":") })
            return try #require(UInt64(line.split(separator: " ").last?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? ""))
        }
        let pageSize = try #require(vmStat.firstMatch(of: /page size of (\d+) bytes/).flatMap { UInt64($0.1) })
        let cliUsed = VMPages(
            anonymous: try pages("Anonymous pages"),
            purgeable: try pages("Pages purgeable"),
            wired: try pages("Pages wired down"),
            compressor: try pages("Pages occupied by compressor")
        ).usedBytes(pageSize: pageSize)
        let cliPressure = MemoryPressure(level: Int32(level.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        print("R11 vm_stat: used \(StatFormat.memory(cliUsed)), pressure level \(level.trimmingCharacters(in: .whitespacesAndNewlines)) | plugin: used \(StatFormat.memory(first.used))…\(StatFormat.memory(second.used)) of \(StatFormat.memory(first.total)), pressure \(first.pressure?.title ?? "-")")

        #expect(first.total == ProcessInfo.processInfo.physicalMemory)
        #expect(between(cliUsed, first.used, second.used, slack: first.total * 3 / 100))
        #expect(cliPressure != nil)
        #expect(cliPressure == first.pressure || cliPressure == second.pressure)
    }

    /// `df -k /`: capacity and free space within ±1% of the capacity.
    @Test func R11__disk_space_matches_df() async throws {
        let space = try #require(BootDiskSampler().space())
        let df = try await run("/bin/df", ["-k", "/"])
        let fields = try #require(df.split(separator: "\n").dropFirst().first).split(separator: " ")
        let dfTotal = try #require(UInt64(fields[1])) * 1024
        let dfFree = try #require(UInt64(fields[3])) * 1024
        let tolerance = dfTotal / 100
        print("R11 df: total \(StatFormat.diskSize(dfTotal)), free \(StatFormat.diskSize(dfFree)) | plugin: total \(StatFormat.diskSize(space.total)), free \(StatFormat.diskSize(space.free))")

        #expect(between(space.total, dfTotal, dfTotal, slack: tolerance))
        #expect(between(space.free, dfFree, dfFree, slack: tolerance))
    }

    /// The read and the write rate of the boot disk, each on its own, against the byte counters of
    /// the same disk's driver as `ioreg` prints them, run around the collector's two readings (see
    /// `rateRange`). 16 MiB written past the file cache inside the interval give the write rate a
    /// floor of about 13 MB/s, so a collector that swapped the directions fails unless the disk
    /// happens to read as much at the same time.
    @Test func R11__disk_read_and_write_rates_match_ioreg() async throws {
        let disk = try #require(BootDiskSampler().physicalDiskName)
        let collector = StatsCollector(samplers: .live())
        var runs: [ToolRun] = []
        func ioreg() async throws {
            runs.append(try await timedRun("/usr/sbin/ioreg", ["-r", "-c", "IOBlockStorageDriver", "-d", "2", "-l", "-a"]))
        }

        try await ioreg()
        _ = collector.sample()
        try await ioreg()
        try writeToDisk(mebibytes: 16)
        try await Task.sleep(for: .seconds(1))
        try await ioreg()
        let io = try #require(collector.sample().diskIO)
        try await ioreg()

        let counters = try runs.map { try diskCounters(in: $0.output, disk: disk) }
        let read = rateRange(runs, counters.map(\.inbound))
        let written = rateRange(runs, counters.map(\.outbound))
        print("R11 ioreg \(disk): read \(StatFormat.rate(read.lowerBound))…\(StatFormat.rate(read.upperBound)), write \(StatFormat.rate(written.lowerBound))…\(StatFormat.rate(written.upperBound)) | plugin: read \(StatFormat.rate(io.inbound)), write \(StatFormat.rate(io.outbound))")

        #expect(read.contains(io.inbound))
        #expect(written.contains(io.outbound))
    }

    /// The download and the upload rate summed over the interfaces the collector counts, each on its
    /// own, against the link rows of `netstat -ib` run around the collector's two readings (see
    /// `rateRange`).
    @Test func R11__network_rates_match_netstat_per_direction() async throws {
        let collector = StatsCollector(samplers: .live())
        let interfaces = InterfaceSampler()
        var runs: [ToolRun] = []
        func netstat() async throws {
            runs.append(try await timedRun("/usr/sbin/netstat", ["-ib"]))
        }

        try await netstat()
        _ = collector.sample()
        let firstNames = Set(interfaces.counters().keys)
        try await netstat()
        try await Task.sleep(for: .seconds(1))
        try await netstat()
        let rates = try #require(collector.sample().network)
        let names = firstNames.intersection(interfaces.counters().keys)
        try await netstat()
        #expect(!names.isEmpty, "no active non-loopback interface")

        let links = runs.map { netstatLinks($0.output) }
        func sums(_ direction: KeyPath<ByteCounters, UInt64>) -> [UInt64] {
            links.map { run in names.reduce(0) { $0 + (run[$1]?[keyPath: direction] ?? 0) } }
        }
        let received = rateRange(runs, sums(\.inbound))
        let sent = rateRange(runs, sums(\.outbound))
        print("R11 netstat \(names.sorted()): in \(StatFormat.rate(received.lowerBound))…\(StatFormat.rate(received.upperBound)), out \(StatFormat.rate(sent.lowerBound))…\(StatFormat.rate(sent.upperBound)) | plugin: in \(StatFormat.rate(rates.inbound)), out \(StatFormat.rate(rates.outbound))")

        #expect(links.allSatisfy { names.isSubset(of: $0.keys) })
        #expect(received.contains(rates.inbound))
        #expect(sent.contains(rates.outbound))
    }

    /// GPU: IOAccelerator "Device Utilization %" must read 0…100 and agree with the same statistic as
    /// `ioreg -r -c IOAccelerator` prints it. Each read reports the busy share since the previous read
    /// by anyone, so readings milliseconds apart differ by up to 100 points under a bursty load
    /// (artifacts/P28 R11-probe-T82.txt). An attempt reads ioreg, waits 150 ms, reads the plugin,
    /// waits 100 ms and reads ioreg again; with ioreg's own ~80 ms each reading covers about 150–250
    /// ms. Only informative attempts count, those whose two ioreg readings lie within 10 points of
    /// each other, and the plugin agrees with one when it lies between them ±15 points (adjacent
    /// idle windows read 0 or 11–15%). Attempts, 100 ms apart, go on until 9 are informative; at
    /// least 6 of the 9 must agree. Two to one, not 3 of 4: under a bursty Metal load 3 of 20
    /// informative attempts were outliers (a window another reader of the statistic, such as the
    /// installed app, cut short), and 3 of 4 failed one of five loaded runs. If 30 attempts bring
    /// fewer than 9, the test fails and lists them all: it never passes without a comparison. It
    /// takes about 5 s idle and 8 s under load. The rule is `gpuVerdict` (GPUComparisonTests.swift).
    /// A sampler stuck at 50 agreed with no informative attempt, idle or under load.
    @Test func R11__gpu_utilization_reads_0_to_100_like_ioreg() async throws {
        let sampler = AcceleratorSampler()
        func ioreg() async throws -> Int {
            let output = try await run("/usr/sbin/ioreg", ["-r", "-c", "IOAccelerator", "-d", "1"])
            return try #require(output.matches(of: /"Device Utilization %"=(\d+)/).compactMap { Int($0.1) }.max())
        }

        var attempts: [GPUAttempt] = []
        while !gpuAttemptsComplete(attempts) {
            if !attempts.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            let before = try await ioreg()
            try await Task.sleep(for: .milliseconds(150))
            let value = try #require(sampler.utilization())
            try await Task.sleep(for: .milliseconds(100))
            let after = try await ioreg()
            #expect((0...100).contains(value))
            attempts.append(GPUAttempt(before: before, plugin: value, after: after))
        }
        let list = attempts.map(\.description).joined(separator: "; ")
        print("R11 GPU: \(list)")

        let verdict = gpuVerdict(attempts)
        #expect(verdict == .agrees, "\(verdict) over \(attempts.count) attempts: \(list)")
    }

    /// At least one SMC temperature sensor reads, and the averages the tab shows are plausible die
    /// temperatures: 10…120 °C. Apple silicon throttles near 105–110 °C and an average cannot pass
    /// its hottest sensor, so 120 °C leaves room for a fanless M2 under a long build (averages of
    /// 103 °C were seen here) while still rejecting the 0 °C and garbage readings of idle sensors.
    @Test func R11__temperature_sensor_reads_a_plausible_value() async throws {
        // Finds the keys at once instead of in the background.
        let discovery = TemperatureKeyDiscovery(start: { $0() }, listKeys: TemperatureKeyDiscovery.listSMCKeys)
        let reading = try #require(SMCSensorSampler(smc: SMCConnection(), discovery: discovery).sensors())
        let cpu = try #require(reading.cpuTemperature)
        print("R11 SMC: CPU \(StatFormat.temperature(cpu)), GPU \(reading.gpuTemperature.map(StatFormat.temperature) ?? "-")")
        #expect((10...120).contains(cpu))
        if let gpu = reading.gpuTemperature { #expect((10...120).contains(gpu)) }
    }

    /// The fans come from the SMC (`FNum`, absent on fanless Macs). `ioreg -l` lists no fan at all on
    /// a fanless Mac such as this MacBook Air M2 (Mac14,2); then the SMC must report no fan and the fan
    /// row must read 없음.
    @Test func R11__fan_count_matches_ioreg() async throws {
        let reading = try #require(SMCSensorSampler().sensors())
        let ioregListsFans = try await run("/usr/sbin/ioreg", ["-l"]).range(of: "fan", options: .caseInsensitive) != nil
        let model = try await run("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("R11 \(model): ioreg lists fans: \(ioregListsFans) | plugin: \(reading.fans), row \"\(reading.fanText)\"")

        #expect((reading.fans == .noFans) == !ioregListsFans)
        if !ioregListsFans { #expect(reading.fanText == "없음") }
    }
}
