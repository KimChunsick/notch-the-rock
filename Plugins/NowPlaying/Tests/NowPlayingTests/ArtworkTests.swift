import Foundation
import NotchKit
import os
import Testing
@testable import NowPlaying

// A long-lived MediaRemote client can go stale: after a track change the app's helper kept saying
// playing, with the browser's icon as the artwork, while the system had paused with the real cover.
// The stream the launcher starts checks its long-lived helper against fresh ones.

@MainActor private let activityID = NowPlayingPlugin.activityID

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

    func start(onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) -> any StreamHandle {
        let stream = FakeStream(onLine: onLine, onExit: onExit)
        started.append(stream)
        return stream
    }

    func process(_ index: Int) throws -> FakeStream {
        try #require(started.indices.contains(index) ? started[index] : nil, "process \(index) of \(started.count)")
    }
}

@MainActor
private func makeLauncher(_ processes: FakeProcesses, clock: ManualClock) -> PerlHelperLauncher {
    PerlHelperLauncher(
        startProcess: { processes.start(onLine: $0, onExit: $1) },
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
/// says paused. One check runs at a time: a rate-0 line during a check starts no second one (and the
/// check's answer, overtaken by that line, changes nothing). A check that never answers is stopped
/// after 5 s, and later checks still run.
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
    #expect(processes.started.count == 2)

    helper.emit(infoLine(rate: 0, playing: false))
    await advance(clock, by: .seconds(30))
    #expect(processes.started.count == 2)

    helper.emit(infoLine())
    await advance(clock, by: .seconds(12))
    await waitUntil { processes.started.count == 3 }
    let silent = try processes.process(2)
    await advance(clock, by: .seconds(5))
    await waitUntil { silent.isStopped }
    #expect(silent.isStopped)
    await advance(clock, by: .seconds(7))
    await waitUntil { processes.started.count == 4 }
    #expect(processes.started.count == 4)
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
    let plugin = NowPlayingPlugin(context: try makeContext(host: host), launcher: launcher, clock: clock)
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

/// The reader hands each line over as soon as the helper writes it, not once 64 KiB have gathered or
/// the helper has ended: a fresh helper's first line, or a long-lived helper's short pause line, would
/// otherwise wait in the pipe.
@MainActor
@Test func R08__the_reader_delivers_each_line_while_the_helper_runs() async throws {
    var lines: [String] = []
    let process = try LineProcess.start(
        HelperCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo first; sleep 30"]),
        onLine: { lines.append($0) },
        onExit: { _ in }
    )
    await waitUntil { !lines.isEmpty }
    #expect(lines == ["first"])
    process.stop()
}
