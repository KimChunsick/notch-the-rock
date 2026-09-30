import Foundation
import Testing
@testable import SystemStats

// The R11 acceptance check: at the same moment, the plugin's live samplers and the command-line
// tools must agree within the tolerances written next to each comparison. Most comparisons bracket
// the tool between two plugin readings taken right before and right after it (plugin, tool,
// plugin), so a value that moves while the tool runs still has to land between the two.

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

/// Whether `value` lies between `a` and `b` (in either order), widened by `slack`.
private func between<T: BinaryInteger>(_ value: T, _ a: T, _ b: T, slack: T = 0) -> Bool {
    value + slack >= min(a, b) && value <= max(a, b) + slack
}

@MainActor
@Suite(.serialized)
struct R11LiveReadings {
    /// `top -l 2 -n 0 -s 1`: the second sample covers the last second; the plugin's ticks span the
    /// whole run of top (about two seconds, including top's own first sample). Different windows over
    /// a changing load can differ by several points, so the busy share must agree within ±20 points.
    @Test func R11__cpu_total_matches_top() async throws {
        let sampler = HostCPUSampler()
        let before = try #require(sampler.coreTicks())
        let output = try await run("/usr/bin/top", ["-l", "2", "-n", "0", "-s", "1"])
        let after = try #require(sampler.coreTicks())
        let usage = try #require(CPUUsage(from: before, to: after))

        let line = try #require(output.split(separator: "\n").last { $0.hasPrefix("CPU usage:") })
        let match = try #require(line.firstMatch(of: /([\d.]+)% idle/))
        let topBusy = 100 - (Double(match.1) ?? 100)
        print("R11 top: \(line) | plugin: total \(StatFormat.percent(usage.total)), cores \(usage.cores.map(StatFormat.percent))")

        #expect(usage.cores.count == ProcessInfo.processInfo.processorCount)
        #expect(usage.cores.allSatisfy { (0...100).contains($0) })
        #expect(abs(usage.total - topBusy) <= 20)
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

    /// `df -k /`: capacity and free space within ±1% of the capacity. The boot disk's byte counters
    /// against `iostat -Id <disk>` (read + written, in MiB with two decimals): between the two plugin
    /// readings ±0.01 MiB for the rounding.
    @Test func R11__disk_matches_df_and_iostat() async throws {
        let sampler = BootDiskSampler()
        let space = try #require(sampler.space())
        let df = try await run("/bin/df", ["-k", "/"])
        let fields = try #require(df.split(separator: "\n").dropFirst().first).split(separator: " ")
        let dfTotal = try #require(UInt64(fields[1])) * 1024
        let dfFree = try #require(UInt64(fields[3])) * 1024
        let tolerance = dfTotal / 100

        let disk = try #require(sampler.physicalDiskName)
        let before = try #require(sampler.counters())
        let iostat = try await run("/usr/sbin/iostat", ["-Id", disk])
        let after = try #require(sampler.counters())
        let mebibytes = try #require(iostat.split(separator: "\n").last?.split(separator: " ").last.flatMap { Double($0) })
        let cliBytes = UInt64(mebibytes * 1_048_576)
        print("R11 df: total \(StatFormat.diskSize(dfTotal)), free \(StatFormat.diskSize(dfFree)) | plugin: total \(StatFormat.diskSize(space.total)), free \(StatFormat.diskSize(space.free))")
        print("R11 iostat \(disk): \(mebibytes) MiB | plugin: \(before.inbound + before.outbound)…\(after.inbound + after.outbound) bytes")

        #expect(between(space.total, dfTotal, dfTotal, slack: tolerance))
        #expect(between(space.free, dfFree, dfFree, slack: tolerance))
        #expect(between(cliBytes, before.inbound + before.outbound, after.inbound + after.outbound, slack: 10_486))
    }

    /// `netstat -ib` link rows for the same interfaces: the summed byte counters must land exactly
    /// between the two plugin readings (both read the kernel's 64-bit counters, which only grow).
    @Test func R11__network_counters_match_netstat() async throws {
        let sampler = InterfaceSampler()
        let before = sampler.counters()
        let netstat = try await run("/usr/sbin/netstat", ["-ib"])
        let after = sampler.counters()
        let names = Set(before.keys).intersection(after.keys)
        #expect(!names.isEmpty, "no active non-loopback interface")

        var links: [String: ByteCounters] = [:]
        for line in netstat.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ")
            guard fields.count >= 10, fields[2].hasPrefix("<Link#"),
                  let received = UInt64(fields[fields.count - 5]), let sent = UInt64(fields[fields.count - 2])
            else { continue }
            links[String(fields[0])] = ByteCounters(inbound: received, outbound: sent)
        }
        func sum(_ counters: [String: ByteCounters], _ direction: KeyPath<ByteCounters, UInt64>) -> UInt64 {
            names.reduce(0) { $0 + (counters[$1]?[keyPath: direction] ?? 0) }
        }
        print("R11 netstat \(names.sorted()): in \(sum(links, \.inbound)), out \(sum(links, \.outbound)) | plugin: in \(sum(before, \.inbound))…\(sum(after, \.inbound)), out \(sum(before, \.outbound))…\(sum(after, \.outbound))")

        #expect(names.isSubset(of: links.keys))
        #expect(between(sum(links, \.inbound), sum(before, \.inbound), sum(after, \.inbound)))
        #expect(between(sum(links, \.outbound), sum(before, \.outbound), sum(after, \.outbound)))
    }

    /// GPU: IOAccelerator "Device Utilization %" must read 0…100. Compared against the same statistic
    /// as `ioreg -r -c IOAccelerator` prints it: between the two plugin readings ±15 points (the driver
    /// refreshes it on its own schedule while ioreg runs).
    @Test func R11__gpu_utilization_reads_0_to_100_like_ioreg() async throws {
        let sampler = AcceleratorSampler()
        let first = try #require(sampler.utilization())
        let ioreg = try await run("/usr/sbin/ioreg", ["-r", "-c", "IOAccelerator", "-d", "1"])
        let second = try #require(sampler.utilization())
        let cli = try #require(ioreg.matches(of: /"Device Utilization %"=(\d+)/).compactMap { Int($0.1) }.max())
        print("R11 ioreg GPU: \(cli)% | plugin: \(StatFormat.percent(first))…\(StatFormat.percent(second))")

        #expect((0...100).contains(first) && (0...100).contains(second))
        #expect(between(cli, Int(first.rounded()), Int(second.rounded()), slack: 15))
    }

    /// At least one SMC temperature sensor reads, and the averages the tab shows are plausible die
    /// temperatures: 10…120 °C. Apple silicon throttles near 105–110 °C and an average cannot pass
    /// its hottest sensor, so 120 °C leaves room for a fanless M2 under a long build (averages of
    /// 103 °C were seen here) while still rejecting the 0 °C and garbage readings of idle sensors.
    @Test func R11__temperature_sensor_reads_a_plausible_value() async throws {
        SMCSensorSampler.discoverNow()
        let reading = try #require(SMCSensorSampler().sensors())
        let cpu = try #require(reading.cpuTemperature)
        print("R11 SMC: CPU \(StatFormat.temperature(cpu)), GPU \(reading.gpuTemperature.map(StatFormat.temperature) ?? "-")")
        #expect((10...120).contains(cpu))
        if let gpu = reading.gpuTemperature { #expect((10...120).contains(gpu)) }
    }

    /// The fan count comes from the SMC (`FNum`, absent on fanless Macs). `ioreg -l` lists no fan at
    /// all on a fanless Mac such as this MacBook Air M2 (Mac14,2); then the count must be 0 and the fan
    /// row must read 없음.
    @Test func R11__fan_count_matches_ioreg() async throws {
        let reading = try #require(SMCSensorSampler().sensors())
        let ioregListsFans = try await run("/usr/sbin/ioreg", ["-l"]).range(of: "fan", options: .caseInsensitive) != nil
        let model = try await run("/usr/sbin/sysctl", ["-n", "hw.model"]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("R11 \(model): ioreg lists fans: \(ioregListsFans) | plugin: \(reading.fanSpeeds.count) fans, row \"\(reading.fanText)\"")

        #expect(reading.fanSpeeds.isEmpty == !ioregListsFans)
        if !ioregListsFans { #expect(reading.fanText == "없음") }
    }
}
