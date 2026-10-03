import Foundation
import NotchKit
import os
import Testing
@testable import NowPlaying

// A long-lived MediaRemote client can go stale: after a track change the app's helper kept saying
// playing, with the browser's icon as the artwork, while the system had paused with the real cover.
// The stream the launcher starts checks its long-lived helper against fresh ones.

/// A clock that moves only when told: a sleep ends once `advance(by:)` reaches its deadline, or
/// throws when its task is cancelled.
final class ManualClock: Clock {
    typealias Instant = VirtualClock.Instant

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Int: (deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = [:]
        var cancelled: Set<Int> = []
        var lastID = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }

    func advance(by duration: Swift.Duration) {
        let due = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let due = state.sleepers.filter { $0.value.deadline <= state.now }
            for id in due.keys { state.sleepers[id] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in due { continuation.resume() }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let id = state.withLock { state in
            state.lastID += 1
            return state.lastID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let outcome: Result<Void, any Error>? = state.withLock { state in
                    if state.cancelled.remove(id) != nil { return .failure(CancellationError()) }
                    if deadline <= state.now { return .success(()) }
                    state.sleepers[id] = (deadline, continuation)
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let continuation = state.withLock { state -> CheckedContinuation<Void, any Error>? in
                guard let sleeper = state.sleepers.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return nil
                }
                return sleeper.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

/// Lets queued main-actor work run (so timers are waiting), moves the clock, and lets the woken
/// work run.
@MainActor
private func advance(_ clock: ManualClock, by duration: Duration) async {
    try? await Task.sleep(for: .milliseconds(20))
    clock.advance(by: duration)
    try? await Task.sleep(for: .milliseconds(20))
}

/// The stream helper processes a launcher started, in order; the test drives each.
@MainActor
private final class FakeProcesses {
    private(set) var started: [FakeStream] = []
    /// The exit status of each command helper.
    var sendStatus: Int32 = 0
    /// Further stream helpers cannot start.
    var refusesStart = false
    /// The most helpers running at once, counted at each start.
    private(set) var mostRunning = 0

    struct Refused: Error {}

    func start(onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) throws -> any StreamHandle {
        if refusesStart { throw Refused() }
        let stream = FakeStream(onLine: onLine, onExit: onExit)
        started.append(stream)
        mostRunning = max(mostRunning, started.count(where: { !$0.isStopped }))
        return stream
    }

    func process(_ index: Int) throws -> FakeStream {
        try #require(started.indices.contains(index) ? started[index] : nil, "process \(index) of \(started.count)")
    }
}

@MainActor
private func makeLauncher(_ processes: FakeProcesses, clock: ManualClock) -> PerlHelperLauncher {
    PerlHelperLauncher(
        startProcess: { try processes.start(onLine: $0, onExit: $1) },
        runCommand: { _, completion in completion(.success(processes.sendStatus)) },
        clock: clock
    )
}

private let browserIcon = samplePNG(side: 32, hue: 0.1)
private let cover = samplePNG(hue: 0.6)

/// The long-lived helper says playing at rate 0 with the browser's icon: a fresh helper is asked at
/// once. It says paused with the real cover, so its line reaches the plugin and the long-lived helper
/// is replaced, once, without an exit. Late output of the replaced and the fresh helper changes
/// nothing; the replacement's lines go through.
@MainActor
@Test func R08__a_stale_helper_is_corrected_by_a_fresh_one_and_replaced() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    var lines: [String] = []
    var exits: [Int32] = []
    let handle = try makeLauncher(processes, clock: clock).startStream(onLine: { lines.append($0) }, onExit: { exits.append($0) })
    let stale = try processes.process(0)

    let staleLine = infoLine(rate: 0, playing: true, bundleID: "com.google.Chrome", artwork: artworkObject(browserIcon))
    stale.emit(staleLine)
    #expect(lines == [staleLine])
    let fresh = try processes.process(1)

    let freshLine = infoLine(rate: 0, playing: false, bundleID: "com.google.Chrome", artwork: artworkObject(cover))
    fresh.emit(freshLine)
    #expect(lines == [staleLine, freshLine])
    #expect(fresh.isStopped)
    #expect(stale.isStopped)
    let replacement = try processes.process(2)
    #expect(!replacement.isStopped)

    stale.emit(staleLine)
    stale.exit(0)
    fresh.emit(staleLine)
    fresh.exit(0)
    await advance(clock, by: .seconds(30))
    #expect(lines.count == 2)
    #expect(exits.isEmpty)

    replacement.emit(freshLine)
    #expect(lines == [staleLine, freshLine, freshLine])
    #expect(processes.started.count == 3)
    handle.stop()
    #expect(replacement.isStopped)
}

/// A fresh helper that says the same playing flag, item, source app and image (which the long-lived
/// helper's later lines leave out) changes nothing. A command sent through the launcher asks for
/// that check a second later; a command the helper could not send does not.
@MainActor
@Test func R08__a_fresh_helper_that_agrees_changes_nothing_and_a_command_asks_a_second_later() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    processes.sendStatus = 1
    let launcher = makeLauncher(processes, clock: clock)
    var lines: [String] = []
    let handle = try launcher.startStream(onLine: { lines.append($0) }, onExit: { _ in })
    let helper = try processes.process(0)
    helper.emit(infoLine(elapsed: 12, artwork: artworkObject(cover)))
    helper.emit(infoLine(elapsed: 40))
    #expect(processes.started.count == 1)

    launcher.send(.pause) { _ in }
    await advance(clock, by: .seconds(1))
    #expect(processes.started.count == 1)

    processes.sendStatus = 0
    launcher.send(.pause) { _ in }
    await advance(clock, by: .milliseconds(900))
    #expect(processes.started.count == 1)
    await advance(clock, by: .milliseconds(100))
    await waitUntil { processes.started.count == 2 }
    let fresh = try processes.process(1)

    fresh.emit(infoLine(elapsed: 41, artwork: artworkObject(cover)))
    #expect(fresh.isStopped)
    #expect(!helper.isStopped)
    #expect(lines.count == 2)
    #expect(processes.started.count == 2)
    handle.stop()
}

/// While the long-lived helper says playing, a fresh helper checks it every 12 s, and not while it
/// says paused. One check runs at a time: a rate-0 line during a check starts no second one while it
/// runs; the check's answer, overtaken by that line, is not used, and the check the line asked for
/// runs as soon as it ends. A check that never answers is stopped after 5 s, and later checks still run.
@MainActor
@Test func R08__checks_repeat_while_playing_one_at_a_time() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    let launcher = makeLauncher(processes, clock: clock)
    let handle = try launcher.startStream(onLine: { _ in }, onExit: { _ in })
    let helper = try processes.process(0)

    helper.emit(infoLine())
    await advance(clock, by: .seconds(11))
    #expect(processes.started.count == 1)
    await advance(clock, by: .seconds(1))
    await waitUntil { processes.started.count == 2 }
    let first = try processes.process(1)
    helper.emit(infoLine(rate: 0, playing: true))
    #expect(processes.started.count == 2)
    first.emit(infoLine(rate: 0, playing: false))
    #expect(first.isStopped)
    #expect(!helper.isStopped)
    let asked = try processes.process(2)
    asked.emit(infoLine(rate: 0, playing: false))
    #expect(asked.isStopped)
    #expect(!helper.isStopped)
    #expect(processes.started.count == 3)

    helper.emit(infoLine(rate: 0, playing: false))
    await advance(clock, by: .seconds(30))
    #expect(processes.started.count == 3)

    helper.emit(infoLine())
    await advance(clock, by: .seconds(12))
    await waitUntil { processes.started.count == 4 }
    let silent = try processes.process(3)
    await advance(clock, by: .seconds(5))
    await waitUntil { silent.isStopped }
    #expect(silent.isStopped)
    await advance(clock, by: .seconds(7))
    await waitUntil { processes.started.count == 5 }
    #expect(processes.started.count == 5)
    handle.stop()
    #expect(processes.started.allSatisfy { $0.isStopped })
}

/// At a track change the helper can say nothing for a moment. A nothing that lasts under a second
/// and is followed by an item keeps the item and the wings; one that lasts takes them down after a
/// second (R23: within 2 s), and the next item brings them back with its line.
@MainActor
@Test func R08__a_short_nothing_keeps_the_item_and_a_lasting_one_ends_it() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    let host = RecordingHost()
    let plugin = NowPlayingPlugin(context: try makeContext(host: host), launcher: makeLauncher(processes, clock: clock), clock: clock)
    plugin.activate()
    let helper = try processes.process(0)
    helper.emit(infoLine())
    #expect(host.events == [.post(id: activityID, priority: 100)])

    helper.emit(#"{"type":"none"}"#)
    await advance(clock, by: .milliseconds(500))
    helper.emit(infoLine(title: "So What"))
    await advance(clock, by: .seconds(2))
    #expect(host.events.count == 1)
    #expect(plugin.model.track?.title == "So What")

    helper.emit(#"{"type":"none"}"#)
    await advance(clock, by: .milliseconds(900))
    #expect(host.events.count == 1)
    #expect(plugin.model.track?.title == "So What")
    await advance(clock, by: .milliseconds(100))
    await waitUntil { host.events.count == 2 }
    #expect(host.events.last == .clear(id: activityID))
    #expect(plugin.model.state == .nothing)

    helper.emit(infoLine())
    #expect(host.events == [.post(id: activityID, priority: 100), .clear(id: activityID), .post(id: activityID, priority: 100)])
    plugin.deactivate()
    #expect(helper.isStopped)
}

/// An item that says playing but does not move (rate 0) counts as paused: the button offers play and
/// the wings go after the pause grace (R23: within 2 s), unless it moves again first. Without a rate
/// the playing flag stands. Moving again brings the wings back with the line.
@MainActor
@Test func R08__playing_at_rate_zero_counts_as_paused_after_the_grace() async throws {
    let model = NowPlayingModel()
    model.apply(try #require(HelperLine(infoLine(rate: 0, playing: true))))
    #expect(model.track?.isPlaying == false)
    #expect(model.track?.playPauseCommand == .play)
    model.apply(try #require(HelperLine(infoLine(rate: nil, playing: true))))
    #expect(model.track?.isPlaying == true)

    let host = RecordingHost()
    let launcher = FakeLauncher()
    let clock = VirtualClock()
    let plugin = try makePlugin(launcher: launcher, clock: clock, host: host)
    plugin.activate()
    let stream = try #require(launcher.streams.first)
    stream.emit(infoLine())
    #expect(host.events == [.post(id: activityID, priority: 100)])

    clock.parksSleeps = true
    stream.emit(infoLine(rate: 0, playing: true))
    await waitUntil { clock.sleeps.count == 1 }
    #expect(clock.sleeps == [NowPlayingPlugin.pauseGrace])
    #expect(NowPlayingPlugin.pauseGrace <= .seconds(2))
    stream.emit(infoLine(rate: 1, playing: true))
    try await Task.sleep(for: .milliseconds(50))
    #expect(host.events.count == 1)

    clock.parksSleeps = false
    stream.emit(infoLine(rate: 0, playing: true))
    await waitUntil { host.events.count == 2 }
    #expect(host.events.last == .clear(id: activityID))
    stream.emit(infoLine())
    #expect(host.events.last == .post(id: activityID, priority: 100))
    plugin.deactivate()
}

/// `stop()` ends the long-lived helper and a running check, and their later output changes nothing.
/// The long-lived helper's own exit reaches the plugin once and ends a running check too.
@MainActor
@Test func R08__stop_and_exit_end_every_helper() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    let launcher = makeLauncher(processes, clock: clock)
    var lines: [String] = []
    var exits: [Int32] = []
    let handle = try launcher.startStream(onLine: { lines.append($0) }, onExit: { exits.append($0) })
    let helper = try processes.process(0)
    helper.emit(infoLine(rate: 0, playing: true))
    let check = try processes.process(1)

    handle.stop()
    #expect(helper.isStopped)
    #expect(check.isStopped)
    check.emit(infoLine(rate: 0, playing: false))
    helper.emit(#"{"type":"none"}"#)
    helper.exit(0)
    launcher.send(.play) { _ in }
    await advance(clock, by: .seconds(30))
    #expect(lines.count == 1)
    #expect(exits.isEmpty)
    #expect(processes.started.count == 2)

    let second = try launcher.startStream(onLine: { lines.append($0) }, onExit: { exits.append($0) })
    let helper2 = try processes.process(2)
    helper2.emit(infoLine(rate: 0, playing: true))
    let check2 = try processes.process(3)
    helper2.exit(1)
    #expect(exits == [1])
    #expect(check2.isStopped)
    await advance(clock, by: .seconds(30))
    #expect(processes.started.count == 4)
    #expect(exits == [1])
    second.stop()
}

/// A fresh helper that differs only in whether the item plays as the model shows it (the playing flag
/// with the rate) or only in the album corrects the long-lived helper: playing at rate 0 against
/// playing at rate 1, the reverse, and another album with the same title and artist. Its line reaches
/// the plugin, the long-lived helper is replaced once without an exit, and the model ends with what
/// the fresh helper says.
@MainActor
@Test(arguments: [
    (staleRate: 0.0, freshRate: 1.0, freshAlbum: "Kind of Blue"),
    (staleRate: 1.0, freshRate: 0.0, freshAlbum: "Kind of Blue"),
    (staleRate: 1.0, freshRate: 1.0, freshAlbum: "Another Album"),
])
func R08__a_fresh_helper_that_shows_another_playing_state_or_album_corrects_the_stale_one(
    _ change: (staleRate: Double, freshRate: Double, freshAlbum: String)
) async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    let launcher = makeLauncher(processes, clock: clock)
    var lines: [String] = []
    var exits: [Int32] = []
    let handle = try launcher.startStream(onLine: { lines.append($0) }, onExit: { exits.append($0) })
    let stale = try processes.process(0)
    let staleLine = infoLine(rate: change.staleRate, playing: true, artwork: artworkObject(cover))
    stale.emit(staleLine)
    // A rate-0 line asks a fresh helper at once; otherwise the command asks a second later.
    if change.staleRate != 0 {
        launcher.send(.pause) { _ in }
        await advance(clock, by: .seconds(1))
        await waitUntil { processes.started.count == 2 }
    }
    let fresh = try processes.process(1)

    let freshLine = infoLine(
        album: change.freshAlbum, elapsed: 13, timestamp: 1_790_000_001, rate: change.freshRate, playing: true,
        artwork: artworkObject(cover)
    )
    fresh.emit(freshLine)
    #expect(lines == [staleLine, freshLine])
    #expect(fresh.isStopped)
    #expect(stale.isStopped)
    #expect(processes.started.count == 3)
    #expect(try !processes.process(2).isStopped)
    #expect(exits.isEmpty)

    let model = NowPlayingModel()
    for line in lines {
        model.apply(try #require(HelperLine(line)))
    }
    #expect(model.track?.isPlaying == (change.freshRate != 0))
    #expect(model.track?.album == change.freshAlbum)
    handle.stop()
    #expect(processes.started.allSatisfy { $0.isStopped })
}

/// A fresh helper that shows the same as the long-lived one changes nothing: another elapsed time,
/// sample time, length or speed is progress read at another moment, not a stale client, and playing at
/// rate 0 is the same pause as a paused flag.
@MainActor
@Test func R08__a_fresh_helper_that_differs_only_in_progress_or_the_raw_flag_changes_nothing() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    let launcher = makeLauncher(processes, clock: clock)
    var lines: [String] = []
    let handle = try launcher.startStream(onLine: { lines.append($0) }, onExit: { _ in })
    let helper = try processes.process(0)
    helper.emit(infoLine(elapsed: 12, artwork: artworkObject(cover)))
    launcher.send(.pause) { _ in }
    await advance(clock, by: .seconds(1))
    await waitUntil { processes.started.count == 2 }

    try processes.process(1).emit(infoLine(
        duration: 340, elapsed: 75, timestamp: 1_790_000_063, rate: 2, artwork: artworkObject(cover)
    ))
    #expect(lines.count == 1)
    #expect(!helper.isStopped)
    #expect(processes.started.count == 2)

    helper.emit(infoLine(rate: 0, playing: true))
    await waitUntil { processes.started.count == 3 }
    try processes.process(2).emit(infoLine(rate: 0, playing: false, artwork: artworkObject(cover)))
    #expect(lines.count == 2)
    #expect(!helper.isStopped)
    #expect(processes.started.count == 3)
    handle.stop()
}

/// When no new long-lived helper can start after a correction, the fresh line still reaches the plugin
/// and the stream ends with exit -1, reported once; nothing starts or reaches the plugin afterwards.
@MainActor
@Test func R08__a_replacement_that_cannot_start_ends_the_stream_once() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    let launcher = makeLauncher(processes, clock: clock)
    var lines: [String] = []
    var exits: [Int32] = []
    let handle = try launcher.startStream(onLine: { lines.append($0) }, onExit: { exits.append($0) })
    let stale = try processes.process(0)
    let staleLine = infoLine(rate: 0, playing: true)
    stale.emit(staleLine)
    let fresh = try processes.process(1)

    processes.refusesStart = true
    let freshLine = infoLine(rate: 1, playing: true)
    fresh.emit(freshLine)
    #expect(lines == [staleLine, freshLine])
    #expect(exits == [-1])
    #expect(VerifiedStream.restartFailedStatus == -1)
    #expect(stale.isStopped)
    #expect(fresh.isStopped)

    processes.refusesStart = false
    stale.emit(staleLine)
    stale.exit(0)
    fresh.exit(0)
    launcher.send(.pause) { _ in }
    await advance(clock, by: .seconds(30))
    #expect(lines.count == 2)
    #expect(exits == [-1])
    #expect(processes.started.count == 2)
    handle.stop()
}

/// Round 090: a periodic check runs when the long-lived helper writes a stale playing-at-rate-0 line,
/// which shows as paused. The line overtakes the check, so its answer (playing) is not used, and the check
/// the line asks for cannot start while that one runs. With nothing more from the helper or the user, the
/// asked-for check still runs as soon as the overtaken one ends: the notch shows playing again within one
/// check cycle, the stale helper is replaced once without an exit, and no helper is left running.
@MainActor
@Test func R08__a_check_asked_for_during_another_runs_after_it() async throws {
    let clock = ManualClock()
    let processes = FakeProcesses()
    var lines: [String] = []
    var exits: [Int32] = []
    let handle = try makeLauncher(processes, clock: clock).startStream(onLine: { lines.append($0) }, onExit: { exits.append($0) })
    let stale = try processes.process(0)
    let playing = infoLine(rate: 1, playing: true)
    stale.emit(playing)
    await advance(clock, by: VerifiedStream.checkInterval)
    await waitUntil { processes.started.count == 2 }
    let periodic = try processes.process(1)

    stale.emit(infoLine(rate: 0, playing: true))
    #expect(processes.started.count == 2)
    periodic.emit(playing)
    #expect(periodic.isStopped)
    #expect(!stale.isStopped)

    // Silence: no more lines, no command. Every fresh helper says playing.
    var waited = Duration.zero
    while processes.started.count < 3, waited < VerifiedStream.checkInterval {
        await advance(clock, by: .seconds(1))
        waited += .seconds(1)
    }
    try processes.process(2).emit(playing)
    #expect(stale.isStopped)
    let replacement = try processes.process(3)
    #expect(!replacement.isStopped)
    #expect(exits.isEmpty)

    let model = NowPlayingModel()
    for line in lines {
        model.apply(try #require(HelperLine(line)))
    }
    #expect(model.track?.isPlaying == true)
    handle.stop()
    #expect(processes.started.allSatisfy { $0.isStopped })
    #expect(processes.mostRunning <= 2)
}

/// SplitMix64: the same seed gives the same sequence on every run.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Lets queued main-actor work and woken timers run: a few turns of the main actor, then, unless
/// `wait` is zero, a short real wait for timers woken on another thread. Much shorter than `advance`'s
/// 20 ms waits; a timer that runs later only moves its action to a later step.
@MainActor
private func settle(wait: Duration = .zero) async {
    for _ in 0..<3 {
        await Task.yield()
    }
    if wait > .zero {
        try? await Task.sleep(for: wait)
        await Task.yield()
    }
}

/// Random sequences of long-lived lines (true, stale at rate 0, stale playing), commands that change
/// what plays, clock moves (ticks, timeouts, the 1 s waits), and fresh helpers that answer, answer
/// nothing usable, exit without answering or cannot start. After the sequence the helpers go quiet and
/// every fresh helper tells what plays. Then the notch shows what a fresh client says, at most one check
/// ran at a time, no helper is left running, and no exit was reported.
@MainActor
@Test func R08__no_check_request_is_lost_in_random_sequences() async throws {
    // Elapsed time, sample time and length are the same in every line, so two models that show the same
    // are equal.
    let stalled = infoLine(rate: 0, playing: true)
    let states = [infoLine(), infoLine(rate: 0, playing: false), infoLine(title: "So What"), #"{"type":"none"}"#]
    let steps: [Duration] = [.milliseconds(500), .seconds(1), .seconds(5), .seconds(12)]
    for seed in UInt64(1)...240 {
        var generator = SeededGenerator(state: seed)
        func pick(_ count: Int) -> Int { Int.random(in: 0..<count, using: &generator) }
        let clock = ManualClock()
        let processes = FakeProcesses()
        let launcher = makeLauncher(processes, clock: clock)
        var lines: [String] = []
        var exits: [Int32] = []
        let handle = try launcher.startStream(onLine: { lines.append($0) }, onExit: { exits.append($0) })
        var longLived = try processes.process(0)
        /// What a fresh client says now.
        var truth = states[pick(states.count)]
        longLived.emit(truth)

        func runningCheck() -> FakeStream? {
            processes.started.last(where: { !$0.isStopped && $0 !== longLived })
        }
        /// A replacement, if the answer brings one, is the first helper started meanwhile.
        func answer(_ check: FakeStream, with line: String) {
            let before = processes.started.count
            check.emit(line)
            if longLived.isStopped, processes.started.count > before {
                longLived = processes.started[before]
            }
        }

        for _ in 0..<(12 + pick(12)) {
            let move = pick(10)
            processes.refusesStart = move < 6 && pick(8) == 0
            switch move {
            case 0..<3:
                let roll = pick(10)
                longLived.emit(roll < 5 ? truth : roll < 8 ? stalled : states[pick(2) * 2])
            case 3:
                truth = states[pick(states.count)]
                launcher.send(.pause) { _ in }
            case 4, 5:
                await settle()
                clock.advance(by: steps[pick(steps.count)])
                await settle()
            case 6:
                runningCheck()?.exit(0)
            default:
                guard let check = runningCheck() else { break }
                let roll = pick(10)
                answer(check, with: roll < 7 ? truth : roll < 9 ? #"{"type":"unavailable","reason":"x"}"# : "not json")
            }
        }

        // Quiet: no more lines or commands, and every fresh helper tells what plays. Each round lets every
        // timer fire (a waiting request, a tick, a held nothing, a command's wait) and answers the checks.
        processes.refusesStart = false
        for round in 0...4 {
            for _ in 0..<10 {
                guard let check = runningCheck() else { break }
                answer(check, with: truth)
            }
            guard round < 4 else { break }
            await settle()
            clock.advance(by: VerifiedStream.checkInterval + .seconds(1))
            await settle(wait: round < 3 ? .milliseconds(1) : .milliseconds(10))
        }

        let shown = NowPlayingModel()
        for line in lines {
            if let parsed = HelperLine(line) { shown.apply(parsed) }
        }
        let fresh = NowPlayingModel()
        fresh.apply(try #require(HelperLine(truth)))
        #expect(shown.state == fresh.state, "seed \(seed)")
        #expect(processes.mostRunning <= 2, "seed \(seed)")
        #expect(runningCheck() == nil, "seed \(seed)")
        #expect(exits.isEmpty, "seed \(seed)")
        handle.stop()
        #expect(processes.started.allSatisfy { $0.isStopped }, "seed \(seed)")
    }
}

/// The reader hands each line over as soon as the helper writes it, not once 64 KiB have gathered or
/// the helper has ended: a fresh helper's first line, or a long-lived helper's short pause line, would
/// otherwise wait in the pipe. The shell `exec`s its sleep, so stopping it leaves no child behind; the
/// exit arrives only once nothing holds the output open.
@MainActor
@Test func R08__the_reader_delivers_each_line_while_the_helper_runs() async throws {
    var lines: [String] = []
    var exited = false
    let process = try LineProcess.start(
        HelperCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo first; exec sleep 30"]),
        onLine: { lines.append($0) },
        onExit: { _ in exited = true }
    )
    await waitUntil { !lines.isEmpty }
    #expect(lines == ["first"])
    process.stop()
    await waitUntil { exited }
    #expect(exited)
}
