import os
import Testing
@testable import SystemStats

/// Scripted SMC answers. A key without a lookup is one the SMC does not have; a key without a value
/// cannot be read. Counts the lookups of each key.
private final class FakeSMC: SMCReading {
    var lookups: [String: SMCLookup] = [:]
    var values: [String: Double] = [:]
    private(set) var asked: [String: Int] = [:]

    func key(_ name: String) -> SMCLookup {
        asked[name, default: 0] += 1
        return lookups[name] ?? .notFound
    }

    func value(_ key: SMCKey) -> Double? { values[key.name] }

    /// Makes `name` a key of the SMC, holding `value` when one is given.
    func add(_ name: String, type: String = "flt ", value: Double? = nil) {
        lookups[name] = .found(SMCKey(code: SMCConnection.code(name), size: type == "ui8 " ? 1 : 4, type: SMCConnection.code(type)))
        values[name] = value
    }
}

@MainActor
@Test func R11__fan_row_reads_none_only_when_the_smc_says_there_is_no_fan() {
    // A fanless Mac such as this MacBook Air M2 has no FNum key: the SMC answers "no such key" (0x84).
    #expect(SMCSensorSampler(smc: FakeSMC()).sensors()?.fanText == "없음")

    let noFans = FakeSMC()
    noFans.add("FNum", type: "ui8 ", value: 0)
    #expect(SMCSensorSampler(smc: noFans).sensors()?.fanText == "없음")
}

@MainActor
@Test func R11__fans_the_smc_cannot_count_read_unavailable_and_are_asked_again_later() {
    var time = 100.0
    let smc = FakeSMC()
    smc.lookups["FNum"] = .failed
    let sampler = SMCSensorSampler(smc: smc, now: { time })
    #expect(sampler.sensors()?.fanText == "—")

    // Not asked again before 30 s have passed.
    smc.add("FNum", type: "ui8 ", value: 2)
    smc.add("F0Ac", value: 1_200)
    time += 29
    #expect(sampler.sensors()?.fanText == "—")
    #expect(smc.asked["FNum"] == 1)

    // FNum is read now, but a fan it counts has no speed key: still unavailable, not one fan fewer.
    time += 1
    #expect(sampler.sensors()?.fanText == "—")
    #expect(smc.asked["FNum"] == 2)

    // An FNum that cannot be read is unavailable too, not "no fans".
    smc.add("F1Ac", value: 1_350)
    smc.values["FNum"] = nil
    time += 30
    #expect(sampler.sensors()?.fanText == "—")

    // Once the fans are found they are kept and only their speeds are read.
    smc.values["FNum"] = 2
    time += 30
    #expect(sampler.sensors()?.fanText == "1200 rpm · 1350 rpm")
    time += 30
    #expect(sampler.sensors()?.fanText == "1200 rpm · 1350 rpm")
    #expect(smc.asked["FNum"] == 4)
}

@MainActor
@Test func R11__a_fan_speed_that_cannot_be_read_is_unavailable_not_zero_rpm() {
    let smc = FakeSMC()
    smc.add("FNum", type: "ui8 ", value: 2)
    smc.add("F0Ac", value: 1_200)
    smc.add("F1Ac")
    #expect(SMCSensorSampler(smc: smc).sensors()?.fanText == "1200 rpm · —")
}

/// Scripted answers of a temperature key listing: each call takes the next answer, nil for a listing
/// that failed. Counts the calls.
private final class KeyListings: Sendable {
    private let state: OSAllocatedUnfairLock<(answers: [[SMCKey]?], calls: Int)>

    init(_ answers: [[SMCKey]?]) {
        state = OSAllocatedUnfairLock(initialState: (answers, 0))
    }

    var calls: Int { state.withLock { $0.calls } }

    func next() -> [SMCKey]? {
        state.withLock { state in
            state.calls += 1
            return state.answers.isEmpty ? nil : state.answers.removeFirst()
        }
    }
}

private func floatKey(_ name: String) -> SMCKey {
    SMCKey(code: SMCConnection.code(name), size: 4, type: SMCConnection.code("flt "))
}

/// The P11 finding: a failed temperature key listing (no connection, an unreadable `#KEY`) is not
/// kept as "no sensors" for the process. It is tried again 30 s later until it succeeds; keys once
/// found are kept for every later sampler, and a listing that found no key is an answer and final.
@MainActor
@Test func R16__a_failed_temperature_key_discovery_is_tried_again_later() {
    var time = 100.0
    let smc = FakeSMC()
    smc.add("Tp01", value: 52)
    smc.add("Tg05", value: 41)
    let listings = KeyListings([nil, nil, [floatKey("Tp01"), floatKey("Tg05")]])
    let discovery = TemperatureKeyDiscovery(start: { $0() }, listKeys: { listings.next() })
    let sampler = SMCSensorSampler(smc: smc, discovery: discovery, now: { time })

    #expect(sampler.sensors()?.cpuTemperature == nil)
    #expect(listings.calls == 1)

    // Not tried again before 30 s have passed.
    time += 29
    #expect(sampler.sensors()?.cpuTemperature == nil)
    #expect(listings.calls == 1)

    // Tried again, failing once more, then again 30 s later, finding the keys.
    time += 1
    #expect(sampler.sensors()?.cpuTemperature == nil)
    #expect(listings.calls == 2)
    time += 30
    let reading = sampler.sensors()
    #expect(reading?.cpuTemperature == 52 && reading?.gpuTemperature == 41)
    #expect(listings.calls == 3)

    // Found keys are kept, also for the sampler of a later activation.
    time += 600
    #expect(sampler.sensors()?.cpuTemperature == 52)
    #expect(SMCSensorSampler(smc: smc, discovery: discovery, now: { time }).sensors()?.cpuTemperature == 52)
    #expect(listings.calls == 3)

    // An SMC that listed its keys and has no temperature key is not asked again.
    let none = KeyListings([[]])
    let noSensors = SMCSensorSampler(smc: smc, discovery: TemperatureKeyDiscovery(start: { $0() }, listKeys: { none.next() }), now: { time })
    #expect(noSensors.sensors()?.cpuTemperature == nil)
    time += 600
    #expect(noSensors.sensors()?.cpuTemperature == nil)
    #expect(none.calls == 1)
}
