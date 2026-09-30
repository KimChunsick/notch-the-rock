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
