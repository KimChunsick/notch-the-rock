import Testing
@testable import SystemStats

// The rule the live GPU test in LiveReadingsTests.swift applies, kept free of ioreg so that readings
// recorded on this Mac can be replayed through it. Each read of IOAccelerator "Device Utilization %"
// reports the GPU's busy share since the previous read, by any reader: reads 2 ms apart return 0
// even under load, reads 150 ms or more apart a steady share. An attempt reads ioreg, then the
// plugin, then ioreg again, about 150 ms apart, so the three readings cover adjacent windows of
// similar length. Adjacent windows still differ: idle, a window reads 0 or 11–15% depending on
// whether it caught the desktop's small bursts of drawing, and another reader of the statistic (the
// installed app, for one) shortens whichever window it falls in. The numbers below come from
// artifacts/P28 R11-probe-T82.txt.

/// One attempt of the live comparison: ioreg's reading, the plugin's, then ioreg's again.
struct GPUAttempt: CustomStringConvertible {
    var before: Int
    var plugin: Double
    var after: Int

    /// The points two ioreg readings may differ by and still say what the GPU did around the plugin's.
    static let informativeSlack = 10
    /// The points the plugin's reading may lie outside the two ioreg readings: the 0 against 11–15%
    /// of adjacent idle windows. At ±10 that alone failed 6 of 19 informative idle attempts; at ±15
    /// every one of the 66 informative attempts recorded idle and under load agreed.
    static let agreementSlack = 15

    /// The two ioreg readings agree with each other, so the GPU's share held steady across the
    /// attempt and the plugin's reading can be judged against them.
    var isInformative: Bool { abs(before - after) <= Self.informativeSlack }

    /// The plugin's reading lies between the two ioreg readings, widened by `agreementSlack`.
    var agrees: Bool {
        Double(min(before, after) - Self.agreementSlack) <= plugin
            && plugin <= Double(max(before, after) + Self.agreementSlack)
    }

    var description: String {
        let note = !isInformative ? " (ioreg moved)" : agrees ? "" : " (outside)"
        return "ioreg \(before)%…\(after)% | plugin \(StatFormat.percent(plugin))\(note)"
    }
}

enum GPUVerdict: Equatable {
    /// At least 2 of every 3 informative attempts agree.
    case agrees
    case disagrees
    /// The attempt budget ran out before 9 attempts were informative: nothing can be said.
    case tooFewInformative
}

/// Whether the live test has collected enough attempts: 9 informative ones, or 30 attempts in all.
/// Under load only half the attempts were informative, hence the budget.
func gpuAttemptsComplete(_ attempts: [GPUAttempt]) -> Bool {
    attempts.count >= 30 || attempts.filter(\.isInformative).count >= 9
}

/// Only informative attempts count; a clear majority of them, two to one, must agree. Under load 3
/// of 20 informative attempts were outliers (a window another reader cut short): 3 of 4 would fail
/// about one loaded run in ten, 6 of 9 about one in thirty, and a constant 50 agreed with none.
func gpuVerdict(_ attempts: [GPUAttempt]) -> GPUVerdict {
    let informative = attempts.filter(\.isInformative)
    guard informative.count >= 9 else { return .tooFewInformative }
    return informative.filter(\.agrees).count * 3 >= informative.count * 2 ? .agrees : .disagrees
}

/// The verdicts the live test reaches on `recorded` when it starts at each attempt in turn, with every
/// plugin reading replaced by `constant` when one is given. A start too close to the end of the
/// recording to complete is left out: the live test would have gone on measuring.
private func replay(_ recorded: [GPUAttempt], constant: Double? = nil) -> [GPUVerdict] {
    let attempts = recorded.map { GPUAttempt(before: $0.before, plugin: constant ?? $0.plugin, after: $0.after) }
    return attempts.indices.compactMap { start in
        var collected: [GPUAttempt] = []
        for attempt in attempts[start...] where !gpuAttemptsComplete(collected) {
            collected.append(attempt)
        }
        return gpuAttemptsComplete(collected) ? gpuVerdict(collected) : nil
    }
}

private func attempts(_ triples: [(Int, Double, Int)]) -> [GPUAttempt] {
    triples.map { GPUAttempt(before: $0.0, plugin: $0.1, after: $0.2) }
}

@Test func R11__gpu_rule_counts_only_informative_attempts_and_needs_two_of_three() {
    #expect(GPUAttempt(before: 40, plugin: 0, after: 50).isInformative)
    #expect(!GPUAttempt(before: 40, plugin: 0, after: 51).isInformative)
    #expect(GPUAttempt(before: 40, plugin: 25, after: 50).agrees)
    #expect(GPUAttempt(before: 40, plugin: 65, after: 50).agrees)
    #expect(!GPUAttempt(before: 40, plugin: 24.4, after: 50).agrees)

    let agreeing = GPUAttempt(before: 80, plugin: 82, after: 84)
    let outside = GPUAttempt(before: 80, plugin: 50, after: 84)
    let moved = GPUAttempt(before: 100, plugin: 50, after: 0)
    func repeated(_ attempt: GPUAttempt, _ count: Int) -> [GPUAttempt] { Array(repeating: attempt, count: count) }
    #expect(gpuVerdict(repeated(agreeing, 6) + repeated(moved, 2) + repeated(outside, 3)) == .agrees)
    #expect(gpuVerdict(repeated(agreeing, 5) + repeated(outside, 4)) == .disagrees)
    #expect(!gpuAttemptsComplete(repeated(agreeing, 8)))
    #expect(gpuAttemptsComplete(repeated(agreeing, 9)))
    // Wide brackets say nothing, however many agree: the budget runs out and the test fails.
    #expect(!gpuAttemptsComplete(repeated(moved, 29)))
    #expect(gpuAttemptsComplete(repeated(moved, 30)))
    #expect(gpuVerdict(repeated(moved, 30) + repeated(agreeing, 8)) == .tooFewInformative)
}

/// The attempts the T79 version of the live test printed (artifacts/P28 R11-stability-T79.txt runs
/// 1–5 and R11-green-T79.txt; it stopped at the first attempt that agreed). In each, the two ioreg
/// readings differ by 13 to 100 points, so not one attempt is informative and the new rule can say
/// nothing about any of these runs, about the real readings or about a constant 0, 50 or 100 alike.
/// The P14 failures (R07-test-sh-T76*.txt) read the plugin, then ioreg, then the plugin, so each
/// holds a single ioreg reading and no attempt can be formed from it.
@Test func R11__gpu_rule_finds_no_informative_attempt_in_the_t79_recordings() {
    let runs = [
        attempts([(62, 78, 100)]),
        attempts([(99, 0, 27), (88, 0, 22), (81, 100, 0), (84, 64, 99), (74, 100, 0), (82, 0, 0)]),
        attempts([(99, 0, 63), (87, 24, 100), (68, 100, 99)]),
        attempts([(100, 22, 0)]),
        attempts([(39, 0, 0)]),
        attempts([(22, 0, 0)]),
    ]
    for run in runs {
        #expect(run.allSatisfy { !$0.isInformative })
        for constant in [nil, 0, 50, 100] as [Double?] {
            let replaced = run.map { GPUAttempt(before: $0.before, plugin: constant ?? $0.plugin, after: $0.after) }
            #expect(gpuVerdict(replaced) == .tooFewInformative)
        }
    }
}

/// Attempts recorded on this Mac with the live test's timing (artifacts/P28 R11-probe-T82.txt). Run
/// from any attempt on, the real readings pass and a sampler stuck at 0, 50 or 100 fails, except where
/// the constant lies within ±15 of what the GPU really did: 0 while the desktop idles (0–17%), and
/// 100 under the load of section 3, which kept the GPU 85–96% busy almost throughout.
@Test func R11__gpu_rule_passes_recorded_readings_and_fails_constant_ones() {
    // Section 8: idle while the desktop drew small bursts.
    let idle = attempts([
        (0, 10, 9), (15, 13, 0), (10, 13, 14), (0, 11, 0), (9, 12, 12), (0, 11, 0),
        (11, 11, 0), (12, 10, 13), (0, 12, 0), (12, 13, 0), (12, 15, 11), (15, 12, 0),
        (12, 11, 12), (0, 14, 13), (11, 11, 14), (11, 0, 11), (12, 15, 0), (11, 14, 0),
        (14, 14, 13), (17, 12, 10), (0, 11, 15), (0, 12, 0), (13, 17, 0), (11, 15, 0),
        (13, 12, 14), (11, 0, 13), (13, 10, 15), (14, 12, 0), (11, 14, 12), (14, 14, 10),
    ])
    // Section 3: a bursty Metal load kept the GPU 75–96% busy.
    let heavy = attempts([
        (85, 79, 36), (77, 90, 66), (86, 85, 87), (87, 85, 81), (85, 94, 77), (89, 93, 89),
        (87, 94, 92), (95, 88, 96), (92, 92, 95), (95, 93, 94), (91, 92, 89), (90, 94, 87),
        (93, 86, 92), (87, 93, 94), (92, 95, 77), (96, 91, 87), (91, 92, 81), (91, 89, 92),
        (94, 83, 90), (83, 93, 88), (90, 96, 94), (90, 93, 100), (92, 98, 92), (95, 95, 88),
        (96, 91, 92), (96, 100, 92), (88, 93, 93), (93, 90, 92), (95, 93, 93), (89, 88, 87),
        (82, 88, 90), (87, 83, 59), (82, 72, 80), (85, 68, 80), (75, 78, 84), (85, 72, 82),
        (73, 75, 74), (81, 77, 86), (79, 71, 86), (0, 74, 85),
    ])
    // Section 11: the attempts of the five loaded runs one after another, 60–89% busy.
    let loaded = attempts([
        (22, 78, 82), (60, 71, 67), (80, 70, 85), (85, 66, 77), (71, 79, 99), (74, 79, 67),
        (59, 90, 78), (72, 72, 78), (88, 72, 75), (71, 80, 67), (82, 72, 87), (79, 83, 99),
        (83, 79, 58), (81, 82, 97), (69, 83, 72), (84, 83, 82), (86, 55, 77), (77, 79, 87),
        (84, 78, 67), (72, 0, 45), (18, 87, 67), (86, 76, 61), (83, 59, 78), (57, 80, 73),
        (80, 79, 82), (74, 79, 87), (68, 65, 69), (84, 77, 48), (68, 85, 72), (89, 79, 79),
        (99, 68, 76), (77, 99, 80), (0, 73, 58), (82, 81, 72), (88, 88, 61), (80, 80, 78),
        (59, 81, 0), (76, 84, 88), (73, 73, 67),
    ])

    for recorded in [idle, heavy, loaded] {
        let real = replay(recorded)
        #expect(!real.isEmpty && real.allSatisfy { $0 == .agrees })
        let fifty = replay(recorded, constant: 50)
        #expect(!fifty.isEmpty && fifty.allSatisfy { $0 == .disagrees })
    }
    #expect(replay(idle, constant: 0).allSatisfy { $0 == .agrees })
    #expect(replay(idle, constant: 100).allSatisfy { $0 == .disagrees })
    #expect(replay(heavy, constant: 0).allSatisfy { $0 == .disagrees })
    #expect(replay(loaded, constant: 0).allSatisfy { $0 == .disagrees })
    #expect(replay(heavy, constant: 100).allSatisfy { $0 == .agrees })
    #expect(replay(loaded, constant: 100).allSatisfy { $0 == .disagrees })
}
