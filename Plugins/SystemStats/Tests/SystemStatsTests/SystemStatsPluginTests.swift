import AppKit
import Foundation
import NotchKit
import os
import SwiftUI
import Testing
@testable import SystemStats

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

/// Activating twice makes the samplers and takes the first reading once, so one refresh loop runs;
/// deactivating ends it and empties the model; activating again starts as the first activation did.
@MainActor
@Test func R64__stats_activate_once_and_start_afresh_after_deactivate() async throws {
    let system = FakeSystem()
    var made = 0
    let plugin = SystemStatsPlugin(context: try makeContext(), interval: .milliseconds(20)) {
        made += 1
        return system.samplers
    }

    plugin.activate()
    plugin.activate()
    #expect(made == 1)
    #expect(system.cpuReads == 1)

    plugin.deactivate()
    #expect(plugin.snapshot == nil)
    // No loop is left running: neither the first nor one a second activation could have started.
    try await Task.sleep(for: .milliseconds(200))
    #expect(system.cpuReads == 1)

    plugin.activate()
    #expect(made == 2)
    #expect(system.cpuReads == 2)
    #expect(plugin.snapshot?.gpu == 12)
    plugin.deactivate()
    #expect(plugin.snapshot == nil)
}

/// The app's tile frames (`HomeGrid` in the app: 40 pt units 10 pt apart) and the largest content of
/// the expanded notch (`NotchSizing.maxContentSize`, the home grid's width).
private let tileFrames: [TileSize: CGSize] = [
    .small: CGSize(width: 90, height: 90),
    .wide: CGSize(width: 190, height: 90),
    .large: CGSize(width: 190, height: 190),
]
private let largestTab = CGSize(width: 390, height: 400)

private func expectDefinite(_ size: CGSize, within limit: CGSize, _ what: String) {
    #expect(size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite, "\(what): \(size)")
    #expect(size.width <= limit.width && size.height <= limit.height, "\(what): \(size) does not fit \(limit)")
}

/// A snapshot with the longest texts the cards show: every core busy, critical memory pressure, two
/// spinning fans and rates in GB/s.
private let busySnapshot = SystemSnapshot(
    cpu: CPUUsage(total: 100, cores: Array(repeating: 100, count: 12)),
    gpu: 100,
    memory: MemoryReading(used: 63 << 30, total: 64 << 30, pressure: .critical),
    disk: DiskSpace(total: 8_000_000_000_000, free: 7_999_000_000_000),
    diskIO: Throughput(inbound: 7.5e9, outbound: 6.5e9),
    network: Throughput(inbound: 999e6, outbound: 999e6),
    sensors: SensorReading(cpuTemperature: 105, gpuTemperature: 99, fans: .speeds([6_000, nil]))
)

/// The tile comes small, wide or large, and every size and the tab have a definite size that fits
/// the app's frame for it, before the first reading and with the longest readings.
@MainActor
@Test func R16__stats_tile_and_tab_fit_the_home_at_every_size() throws {
    let plugin = SystemStatsPlugin(context: try makeContext(), interval: .seconds(3600)) { FakeSystem().samplers }
    let tile = try #require(plugin.tile)
    #expect(tile.supportedSizes == [.small, .wide, .large])
    #expect(tile.defaultSize == .small)

    let empty = SystemStatsModel()
    let busy = SystemStatsModel()
    busy.record(busySnapshot)
    busy.record(busySnapshot)
    for (name, model) in [("empty", empty), ("busy", busy)] {
        for size in tile.supportedSizes {
            let fitting = NSHostingView(rootView: SystemStatsTile(model: model, size: size)).fittingSize
            expectDefinite(fitting, within: try #require(tileFrames[size]), "\(name) \(size)")
        }
        expectDefinite(NSHostingView(rootView: SystemStatsView(model: model)).fittingSize, within: largestTab, "\(name) tab")
    }
}

/// The tile shows what the model holds: CPU, memory and temperature of the latest snapshot, and
/// "—" once the plugin is turned off and the model is reset.
@MainActor
@Test func R16__stats_tile_reads_the_model() throws {
    let system = FakeSystem()
    system.ticks = [
        [CoreTicks(user: 0, system: 0, idle: 0, nice: 0)],
        [CoreTicks(user: 25, system: 0, idle: 75, nice: 0)],
    ]
    let collector = StatsCollector(samplers: system.samplers)
    let model = SystemStatsModel()
    let tile = SystemStatsTile(model: model, size: .wide)
    #expect(tile.rows.map(\.value) == ["—", "—", "—"])

    model.record(collector.sample(at: 10))
    model.record(collector.sample(at: 12))
    #expect(tile.rows.map(\.title) == ["CPU", "메모리", "온도"])
    #expect(tile.rows.map(\.value) == ["25%", StatFormat.memory(8), "48°C"])
    #expect(tile.rows[0].line.values == model.history.cpu.values)

    model.reset()
    #expect(tile.rows.map(\.value) == ["—", "—", "—"])
}

/// Drawing the tile at every size, and the tab, reads nothing from the system: the refresh loop is
/// the only reader.
@MainActor
@Test func R16__drawing_the_tile_adds_no_reading() throws {
    let system = FakeSystem()
    let plugin = SystemStatsPlugin(context: try makeContext(), interval: .seconds(3600)) { system.samplers }
    plugin.activate()
    defer { plugin.deactivate() }
    #expect(system.cpuReads == 1)

    let tile = try #require(plugin.tile)
    for size in tile.supportedSizes {
        _ = NSHostingView(rootView: tile.content(size)).fittingSize
    }
    _ = NSHostingView(rootView: try #require(plugin.expandedTab).content).fittingSize
    #expect(system.cpuReads == 1)
}

/// How far the outermost ink of `view` (any channel at least 14 over black, as the end-to-end
/// capture counts it) stays from its left, right and bottom edges, drawn offscreen at its ideal
/// size. The host adds the notch's margin around a tab, so a tab's own outer padding shows here.
@MainActor
private func inkInsets(_ view: some View) throws -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    // Measured in the window, at its backing scale, as the app measures a tab.
    let size = hosting.fittingSize
    window.setContentSize(size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = try #require(rep.cgImage)
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var minX = width, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 14 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    try #require(maxX >= 0, "no ink in \(size)")
    let scale = window.backingScaleFactor
    return (CGFloat(minX) / scale, CGFloat(width - 1 - maxX) / scale, CGFloat(height - 1 - maxY) / scale)
}

/// Expects `insets` within R15's 2 pt tolerance: a line's descent or a glyph's side bearing stays
/// inside it, outer padding or a frame larger than the ink does not.
private func expectNoOuterSpace(_ insets: (left: CGFloat, right: CGFloat, bottom: CGFloat), _ what: String) {
    print("R15 \(what): ink insets left \(insets.left) right \(insets.right) bottom \(insets.bottom) pt")
    for (side, inset) in [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)] {
        #expect(inset <= 2, "\(what): \(inset) pt of empty space at the \(side) edge")
    }
}


/// The tab is the size of what it draws, before the first reading and with the longest readings:
/// the host adds the margin around it.
@MainActor
@Test func R15__stats_tab_draws_to_its_edges() throws {
    let empty = SystemStatsModel()
    let busy = SystemStatsModel()
    busy.record(busySnapshot)
    busy.record(busySnapshot)
    for (name, model) in [("empty", empty), ("busy", busy)] {
        expectNoOuterSpace(try inkInsets(SystemStatsView(model: model)), name)
    }
}

/// Offered more width than its own, as the host does when the band beside the camera makes the
/// notch wider than the screen, the cards spread to both edges of the offer without wrapping; at its
/// own width the screen keeps today's size.
@MainActor
@Test func R15__stats_screen_fills_a_wider_offer() throws {
    let busy = SystemStatsModel()
    busy.record(busySnapshot)
    busy.record(busySnapshot)
    let view = SystemStatsView(model: busy)
    let ideal = NSHostingView(rootView: view).fittingSize
    print("R15 stats ideal \(ideal)")
    // Today's size.
    #expect(abs(ideal.width - 382) <= 0.5 && abs(ideal.height - 210) <= 0.5, "the screen's own size changed: \(ideal)")
    let offered = ideal.width + 80
    let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
    #expect(abs(wide.height - ideal.height) <= 1, "wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
    let insets = try inkInsets(view.frame(width: offered))
    print("R15 stats offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
    #expect(insets.left <= 2 && insets.right <= 2, "the screen does not reach both edges of a \(offered) pt offer: \(insets)")
}
