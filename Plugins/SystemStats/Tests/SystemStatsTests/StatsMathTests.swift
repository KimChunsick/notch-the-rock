import Testing
@testable import SystemStats

@Test func R11__tick_deltas_give_per_core_and_total_percent() throws {
    let old = [
        CoreTicks(user: 100, system: 50, idle: 1000, nice: 0),
        // Tick counters are 32-bit and wrap: this core's user count passes UInt32.max.
        CoreTicks(user: UInt32.max - 9, system: 0, idle: 500, nice: 0),
    ]
    let new = [
        CoreTicks(user: 120, system: 60, idle: 1070, nice: 0),  // busy 30 of 100
        CoreTicks(user: 40, system: 0, idle: 550, nice: 0),     // busy 50 of 100 across the wrap
    ]
    let usage = try #require(CPUUsage(from: old, to: new))
    #expect(usage.cores == [30, 50])
    #expect(usage.total == 40)

    // An idle interval with no ticks at all reads 0%, and a changed core count has no usage.
    #expect(CPUUsage(from: old, to: old)?.cores == [0, 0])
    #expect(CPUUsage(from: old, to: Array(new.prefix(1))) == nil)
}

@Test func R11__counter_deltas_give_rates_and_skip_resets() throws {
    #expect(byteRate(from: 1_000, to: 3_000, seconds: 2) == 1_000)
    // 64-bit counters keep counting past 4 GiB instead of wrapping.
    #expect(byteRate(from: 4_294_967_000, to: 4_294_969_000, seconds: 2) == 1_000)
    // A counter that went backwards was reset; the interval has no rate.
    #expect(byteRate(from: 3_000, to: 100, seconds: 2) == nil)
    #expect(byteRate(from: 1_000, to: 3_000, seconds: 0) == nil)

    let old: [String: ByteCounters] = [
        "en0": ByteCounters(inbound: 1_000, outbound: 0),
        "en1": ByteCounters(inbound: 9_000, outbound: 9_000),   // resets below
        "awdl0": ByteCounters(inbound: 500, outbound: 500),     // disappears below
    ]
    let new: [String: ByteCounters] = [
        "en0": ByteCounters(inbound: 5_000, outbound: 1_000),
        "en1": ByteCounters(inbound: 10, outbound: 10),
        "utun4": ByteCounters(inbound: 1_000_000, outbound: 1_000_000),  // appeared
    ]
    // Only en0 is in both readings with growing counters: 4,000 and 1,000 bytes over 2 s.
    #expect(Throughput(from: old, to: new, seconds: 2) == Throughput(inbound: 2_000, outbound: 500))
    // With no interface in both readings there is no rate.
    #expect(Throughput(from: [:], to: new, seconds: 2) == nil)
}

@Test(arguments: [
    (0.0, "0 KB/s"),
    (340_000.0, "340 KB/s"),
    (1_234_567.0, "1.2 MB/s"),
    (12_345_678.0, "12 MB/s"),
    (1_500_000_000.0, "1.5 GB/s"),
])
func R11__rates_are_formatted_in_decimal_units(bytesPerSecond: Double, text: String) {
    #expect(StatFormat.rate(bytesPerSecond) == text)
}

@Test func R11__sizes_percentages_and_temperatures_are_formatted() {
    // Disk sizes use decimal units like Finder: a 494 GB SSD reads 494 GB.
    #expect(StatFormat.diskSize(494_384_795_648) == "494 GB")
    #expect(StatFormat.diskSize(57_300_000_000) == "57.3 GB")
    #expect(StatFormat.diskSize(2_000_000_000_000) == "2.0 TB")
    // Memory uses binary units like Activity Monitor: 16 GiB of RAM reads 16.0 GB.
    #expect(StatFormat.memory(17_179_869_184) == "16.0 GB")
    #expect(StatFormat.memory(9_771_050_598) == "9.1 GB")
    #expect(StatFormat.percent(42.4) == "42%")
    #expect(StatFormat.percent(99.6) == "100%")
    #expect(StatFormat.temperature(52.6) == "53°C")
}

@Test func R11__history_keeps_the_last_points_oldest_first() {
    var history = History(capacity: 3)
    history.append(1)
    history.append(2)
    #expect(history.values == [1, 2])
    history.append(3)
    history.append(4)
    history.append(5)
    #expect(history.values == [3, 4, 5])
}

@Test func R11__fan_row_shows_none_on_a_mac_without_fans() {
    #expect(SensorReading(cpuTemperature: 45, gpuTemperature: nil, fanSpeeds: []).fanText == "없음")
    #expect(SensorReading(cpuTemperature: 45, gpuTemperature: nil, fanSpeeds: [1200, 1350.4]).fanText == "1200 rpm · 1350 rpm")
}

@Test func R11__memory_used_is_app_wired_and_compressed_pages() {
    // Activity Monitor's "Memory Used": app memory (anonymous minus purgeable) + wired + compressed.
    let pages = VMPages(anonymous: 400, purgeable: 50, wired: 200, compressor: 100)
    #expect(pages.usedBytes(pageSize: 16_384) == 650 * 16_384)
    let reading = MemoryReading(used: 4, total: 16, pressure: .normal)
    #expect(reading.usedPercent == 25)
}

@Test func R11__pressure_levels_map_like_the_kernel() {
    // kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical.
    #expect(MemoryPressure(level: 1) == .normal)
    #expect(MemoryPressure(level: 2) == .warning)
    #expect(MemoryPressure(level: 4) == .critical)
    #expect(MemoryPressure(level: 3) == nil)
    #expect([MemoryPressure.normal, .warning, .critical].map(\.title) == ["정상", "주의", "심각"])
}
