import Foundation
import NotchKit
import os
import Testing
@testable import SystemStats

@MainActor
private final class SilentHost: NotchHost {
    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// Scripted readings: every call returns the next reading and counts the call.
@MainActor
private final class FakeSystem: CPUSampler, GPUSampler, MemorySampler, DiskSampler, NetworkSampler, SensorSampler {
    var cpuReads = 0
    var ticks: [[CoreTicks]] = []
    var diskCounters: [ByteCounters] = []
    var networkCounters: [[String: ByteCounters]] = []

    func coreTicks() -> [CoreTicks]? {
        defer { cpuReads += 1 }
        return ticks.isEmpty ? nil : ticks[min(cpuReads, ticks.count - 1)]
    }
    func utilization() -> Double? { 12 }
    func memory() -> MemoryReading? { MemoryReading(used: 8, total: 16, pressure: .warning) }
    func space() -> DiskSpace? { DiskSpace(total: 500, free: 200) }
    func counters() -> ByteCounters? { diskCounters.isEmpty ? nil : diskCounters[min(cpuReads - 1, diskCounters.count - 1)] }
    func counters() -> [String: ByteCounters] {
        networkCounters.isEmpty ? [:] : networkCounters[min(cpuReads - 1, networkCounters.count - 1)]
    }
    func sensors() -> SensorReading? { SensorReading(cpuTemperature: 48, gpuTemperature: 40, fans: .noFans) }

    var samplers: Samplers {
        Samplers(cpu: self, gpu: self, memory: self, disk: self, network: self, sensors: self)
    }
}

/// A clock whose time moves only when told: a sleep jumps straight to its deadline, and every sleep
/// after the first `sleeps` parks in a real sleep until its task is cancelled.
private final class VirtualClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleeps: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(sleeps: Int) {
        state = OSAllocatedUnfairLock(initialState: State(sleeps: sleeps))
    }

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }

    func advance(by duration: Swift.Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let park = state.withLock { state in
            guard state.sleeps > 0 else { return true }
            state.sleeps -= 1
            state.now = max(state.now, deadline)
            return false
        }
        if park { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// A CPU reading that takes `durations[n]` of virtual time the n-th time and records when each
/// reading started.
@MainActor
private final class SlowCPU: CPUSampler {
    private let clock: VirtualClock
    private let durations: [Duration]
    private(set) var starts: [Duration] = []

    init(clock: VirtualClock, durations: [Duration]) {
        self.clock = clock
        self.durations = durations
    }

    func coreTicks() -> [CoreTicks]? {
        starts.append(clock.now.offset)
        clock.advance(by: durations[min(starts.count - 1, durations.count - 1)])
        return nil
    }
}

@MainActor
private func makeContext() throws -> NotchContext {
    let id = SystemStatsPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("systemstats-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "systemstats-tests.\(id)",
        keychainService: "systemstats-tests.\(id)"
    )
    return NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: SilentHost(), storage: storage)
}

@MainActor
@Test func R11__collector_turns_two_readings_into_usage_and_rates() throws {
    let system = FakeSystem()
    system.ticks = [
        [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)],
        [CoreTicks(user: 25, system: 0, idle: 75, nice: 0)],
    ]
    system.diskCounters = [ByteCounters(inbound: 0, outbound: 0), ByteCounters(inbound: 4_000, outbound: 2_000)]
    system.networkCounters = [
        ["en0": ByteCounters(inbound: 100, outbound: 100)],
        ["en0": ByteCounters(inbound: 2_100, outbound: 1_100)],
    ]
    let collector = StatsCollector(samplers: system.samplers)
    let model = SystemStatsModel()

    let first = collector.sample(at: 10)
    model.record(first)
    // Rates need two readings; the absolute values are there at once.
    #expect(first.cpu == nil && first.diskIO == nil && first.network == nil)
    #expect(first.gpu == 12 && first.disk == DiskSpace(total: 500, free: 200))
    #expect(first.memory?.pressure == .warning && first.sensors?.fanText == "없음")

    let second = collector.sample(at: 12)
    model.record(second)
    #expect(second.cpu == CPUUsage(total: 25, cores: [25]))
    #expect(second.diskIO == Throughput(inbound: 2_000, outbound: 1_000))
    #expect(second.network == Throughput(inbound: 1_000, outbound: 500))

    // The sparklines only get points for values that were read.
    #expect(model.history.cpu.values == [25])
    #expect(model.history.gpu.values == [12, 12])
    #expect(model.history.memory.values == [50, 50])
    #expect(model.history.networkDown.values == [1_000])
    #expect(model.history.temperature.values == [48, 48])
}

@MainActor
@Test func R11__plugin_refreshes_until_deactivated() async throws {
    #expect(SystemStatsPlugin.refreshInterval <= .seconds(2))

    let system = FakeSystem()
    let plugin = SystemStatsPlugin(context: try makeContext(), interval: .milliseconds(20)) { system.samplers }

    plugin.activate()
    // The first reading is taken at once so the tab never opens empty.
    #expect(system.cpuReads == 1)
    #expect(plugin.snapshot?.gpu == 12)

    // The loop keeps reading at the interval (waiting up to 5 s for a busy main actor).
    let deadline = ContinuousClock.now + .seconds(5)
    while system.cpuReads < 3, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(system.cpuReads >= 3)

    plugin.deactivate()
    #expect(plugin.snapshot == nil)
    let readsAtStop = system.cpuReads
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.cpuReads == readsAtStop)
}

@MainActor
@Test func R11__refreshes_start_every_two_seconds_however_long_a_reading_takes() async throws {
    let clock = VirtualClock(sleeps: 3)
    // Readings take 0.3 s, except the second one, which overruns the interval with 2.5 s.
    let cpu = SlowCPU(clock: clock, durations: [.milliseconds(300), .milliseconds(2_500), .milliseconds(300)])
    let samplers = {
        var samplers = FakeSystem().samplers
        samplers.cpu = cpu
        return samplers
    }()
    let plugin = SystemStatsPlugin(context: try makeContext(), interval: SystemStatsPlugin.refreshInterval, clock: clock) {
        samplers
    }

    plugin.activate()
    let deadline = ContinuousClock.now + .seconds(5)
    while cpu.starts.count < 4, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    // Each reading starts two seconds after the previous one started, not two seconds after it
    // ended; the one after the overrun starts at once, and the cadence then continues from it.
    #expect(cpu.starts == [.zero, .seconds(2), .milliseconds(4_500), .milliseconds(6_500)])

    // The loop now waits in its next sleep; deactivate() ends it without another reading.
    plugin.deactivate()
    try await Task.sleep(for: .milliseconds(200))
    #expect(cpu.starts.count == 4)
}
