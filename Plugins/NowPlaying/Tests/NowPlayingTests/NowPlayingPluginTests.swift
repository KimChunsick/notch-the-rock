import AppKit
import Foundation
import NotchKit
import Testing
@testable import NowPlaying

@MainActor private let activityID = NowPlayingPlugin.activityID

@MainActor
private func makePlugin(launcher: FakeLauncher, clock: VirtualClock = VirtualClock(), host: RecordingHost) throws -> NowPlayingPlugin {
    NowPlayingPlugin(context: try makeContext(host: host), launcher: launcher, clock: clock)
}

/// The model takes each line: an item with its image, the image kept while lines leave it out,
/// replaced or removed when they say so, and cleared with the item when nothing plays, when the
/// helper cannot reach MediaRemote and on a reset.
@MainActor
@Test func R08__model_follows_the_helper_lines() throws {
    let model = NowPlayingModel()
    #expect(model.state == .nothing)
    #expect(model.artwork == nil)

    model.apply(try #require(HelperLine(infoLine(artwork: artworkObject(samplePNG())))))
    #expect(model.track?.title == "Blue in Green")
    #expect(model.track?.isPlaying == true)
    let cover = try #require(model.artwork)
    #expect(cover.width == 120 && cover.height == 120)

    model.apply(try #require(HelperLine(infoLine(elapsed: 40, playing: false))))
    #expect(model.track?.isPlaying == false)
    #expect(model.track?.elapsed == 40)
    #expect(model.artwork === cover)

    model.apply(try #require(HelperLine(infoLine(title: "So What", artwork: artworkObject(samplePNG(side: 64))))))
    #expect(model.track?.title == "So What")
    #expect(model.artwork?.width == 64)

    model.apply(try #require(HelperLine(infoLine(title: "No cover", artwork: NSNull()))))
    #expect(model.track?.title == "No cover")
    #expect(model.artwork == nil)

    model.apply(try #require(HelperLine(infoLine(artwork: artworkObject(samplePNG())))))
    model.apply(.nothing)
    #expect(model.state == .nothing)
    #expect(model.artwork == nil)

    model.apply(try #require(HelperLine(infoLine(artwork: artworkObject(samplePNG())))))
    model.apply(.unavailable(reason: "cannot load MediaRemote"))
    #expect(model.state == .unavailable)
    #expect(model.artwork == nil)

    model.apply(try #require(HelperLine(infoLine(artwork: artworkObject(samplePNG())))))
    model.reset()
    #expect(model.state == .nothing)
    #expect(model.artwork == nil)
}

/// The wings appear while an item plays (priority 100) or is paused (priority 0) and go away when
/// nothing plays or the plugin is deactivated. A line that changes neither keeps the posted
/// activity, whose views follow the model; a line the plugin cannot read changes nothing.
@MainActor
@Test func R08__wings_follow_playback() throws {
    let host = RecordingHost()
    let launcher = FakeLauncher()
    let plugin = try makePlugin(launcher: launcher, host: host)
    plugin.activate()
    plugin.activate()
    #expect(launcher.streams.count == 1)
    let stream = try #require(launcher.streams.first)

    stream.emit(#"{"type":"none"}"#)
    #expect(host.events.isEmpty)
    stream.emit(infoLine(elapsed: 12))
    #expect(host.events == [.post(id: activityID, priority: 100)])
    #expect(plugin.model.track?.title == "Blue in Green")
    stream.emit(infoLine(title: "Flamenco Sketches", elapsed: 0))
    #expect(host.events.count == 1)
    #expect(plugin.model.track?.title == "Flamenco Sketches")

    stream.emit(infoLine(title: "Flamenco Sketches", rate: 0, playing: false))
    #expect(host.events.last == .post(id: activityID, priority: 0))
    stream.emit("{\"type\":\"info\"")
    #expect(plugin.model.track?.title == "Flamenco Sketches")
    #expect(host.events.count == 2)

    stream.emit(#"{"type":"none"}"#)
    #expect(host.events.last == .clear(id: activityID))
    #expect(plugin.model.state == .nothing)

    stream.emit(infoLine())
    #expect(host.events.last == .post(id: activityID, priority: 100))
    plugin.deactivate()
    #expect(stream.isStopped)
    #expect(host.events.last == .clear(id: activityID))
    #expect(plugin.model.state == .nothing)
    // Output of the stopped helper that was already on its way changes nothing.
    stream.emit(infoLine())
    #expect(plugin.model.state == .nothing)
    #expect(host.events.last == .clear(id: activityID))
}

/// A helper that ends on its own is started again after 1 s, the delay doubling while runs stay
/// short, up to 30 s, and starting over after a run of 30 s or more. What played is unknown in
/// between, so the wings go away. An ended helper's late output is ignored, and deactivating while
/// a restart waits cancels it.
@MainActor
@Test func R08__helper_restarts_with_backoff_until_deactivated() async throws {
    let host = RecordingHost()
    let launcher = FakeLauncher()
    let clock = VirtualClock()
    let plugin = try makePlugin(launcher: launcher, clock: clock, host: host)
    plugin.activate()
    try #require(launcher.streams.count == 1)
    launcher.streams[0].emit(infoLine())
    #expect(host.events == [.post(id: activityID, priority: 100)])

    launcher.streams[0].exit(1)
    #expect(plugin.model.state == .nothing)
    #expect(host.events.last == .clear(id: activityID))
    await waitUntil { launcher.streams.count == 2 }
    try #require(launcher.streams.count == 2)
    for expected in 3...8 {
        launcher.streams[expected - 2].exit(1)
        await waitUntil { launcher.streams.count == expected }
        try #require(launcher.streams.count == expected)
    }
    #expect(clock.sleeps == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30), .seconds(30)])
    #expect(host.logs.contains { $0.0 == .info && $0.1.contains("exit status 1") })

    clock.advance(by: .seconds(30))
    launcher.streams[7].exit(0)
    await waitUntil { launcher.streams.count == 9 }
    try #require(launcher.streams.count == 9)
    #expect(clock.sleeps.last == .seconds(1))

    // An earlier helper's output and exit, arriving late, change nothing.
    launcher.streams[0].emit(infoLine())
    launcher.streams[0].exit(1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(plugin.model.state == .nothing)
    #expect(launcher.streams.count == 9)

    clock.parksSleeps = true
    launcher.streams[8].exit(1)
    await waitUntil { clock.sleeps.count == 9 }
    plugin.deactivate()
    clock.parksSleeps = false
    try await Task.sleep(for: .milliseconds(100))
    #expect(launcher.streams.count == 9)

    // A new activation starts afresh at 1 s and stops its helper on deactivation.
    plugin.activate()
    try #require(launcher.streams.count == 10)
    launcher.streams[9].exit(1)
    await waitUntil { launcher.streams.count == 11 }
    try #require(launcher.streams.count == 11)
    #expect(clock.sleeps.last == .seconds(1))
    plugin.deactivate()
    #expect(launcher.streams[10].isStopped)
}

/// A helper that reports MediaRemote unavailable, or a perl that cannot start, leaves the plugin
/// in the quiet unavailable state with one error in the log, and nothing is started again until the
/// plugin is activated anew.
@MainActor
@Test func R08__unavailable_helper_is_not_restarted() async throws {
    let host = RecordingHost()
    let launcher = FakeLauncher()
    let clock = VirtualClock()
    let plugin = try makePlugin(launcher: launcher, clock: clock, host: host)
    plugin.activate()
    try #require(launcher.streams.count == 1)
    launcher.streams[0].emit(#"{"type":"unavailable","reason":"cannot load MediaRemote: image not found"}"#)
    #expect(plugin.model.state == .unavailable)
    #expect(host.errors.count == 1)
    #expect(host.errors.first?.contains("cannot load MediaRemote: image not found") == true)
    launcher.streams[0].exit(HelperCommand.unavailableStatus)
    try await Task.sleep(for: .milliseconds(100))
    #expect(launcher.streams.count == 1)
    #expect(clock.sleeps.isEmpty)
    #expect(host.events.isEmpty)

    plugin.deactivate()
    plugin.activate()
    #expect(launcher.streams.count == 2)
    #expect(plugin.model.state == .nothing)
    plugin.deactivate()

    launcher.startError = CocoaError(.fileNoSuchFile)
    plugin.activate()
    #expect(plugin.model.state == .unavailable)
    #expect(host.errors.count == 2)
    #expect(host.errors.last?.contains("/usr/bin/perl") == true)
    try await Task.sleep(for: .milliseconds(100))
    #expect(clock.sleeps.isEmpty)
    plugin.deactivate()
}

/// The buttons hand their command to the helper; play/pause sends what it shows. A helper that
/// fails to send, or cannot start, is logged.
@MainActor
@Test func R08__transport_buttons_send_their_commands() throws {
    let host = RecordingHost()
    let launcher = FakeLauncher()
    let plugin = try makePlugin(launcher: launcher, host: host)
    plugin.send(.previous)
    plugin.send(.next)
    #expect(launcher.sent == [.previous, .next])
    #expect(host.errors.isEmpty)

    let sampled = Date(timeIntervalSince1970: 0)
    var pressed: [NowPlayingCommand] = []
    TransportButton.playPause(for: TrackInfo(title: "t", sampledAt: sampled, isPlaying: true), size: 16) { pressed.append($0) }.action()
    TransportButton.playPause(for: TrackInfo(title: "t", sampledAt: sampled, isPlaying: false), size: 16) { pressed.append($0) }.action()
    #expect(pressed == [.pause, .play])

    launcher.sendResult = .success(1)
    plugin.send(.pause)
    #expect(host.errors.last?.contains("pause") == true)
    launcher.sendResult = .failure(CocoaError(.fileNoSuchFile))
    plugin.send(.play)
    #expect(host.errors.count == 2)
    #expect(host.errors.last?.contains("play") == true)
}

/// Runs `command` and returns its exit status and output.
private func run(_ command: HelperCommand) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = command.executable
    process.arguments = command.arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// The real perl driver loads the library it is given and looks up the entry point of the mode:
/// with a system library that has none it reports exactly which one it missed. Nothing here
/// touches MediaRemote or playback.
@Test func R08__perl_driver_looks_up_the_entry_point_of_each_mode() throws {
    let library = URL(fileURLWithPath: "/usr/lib/libSystem.B.dylib")
    var runs = [(HelperCommand.stream(library: library), "nowplaying_stream")]
    for command in NowPlayingCommand.allCases {
        runs.append((.send(command, library: library), "nowplaying_send_\(command.rawValue)"))
    }
    for (command, entry) in runs {
        let result = try run(command)
        #expect(result.status == HelperCommand.unavailableStatus, "\(entry)")
        #expect(HelperLine(result.output.trimmingCharacters(in: .newlines)) == .unavailable(reason: "\(entry) not found in \(library.path)"))
    }
    var unknown = HelperCommand.send(.play, library: library)
    unknown = HelperCommand(executable: unknown.executable, arguments: unknown.arguments.dropLast() + ["stop"])
    let refused = try run(unknown)
    #expect(refused.status == 64)
    #expect(refused.output.isEmpty)
}

/// Installed without its helper library, the plugin starts the real perl driver, shows the quiet
/// unavailable state with the reason in the log, and does not start the helper again.
@MainActor
@Test func R08__plugin_without_its_helper_shows_unavailable() async throws {
    let host = RecordingHost()
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("NowPlaying-\(UUID().uuidString).notchplugin")
    let plugin = NowPlayingPlugin(context: try makeContext(host: host, bundleURL: bundle))
    plugin.activate()
    await waitUntil { plugin.model.state == .unavailable }
    #expect(plugin.model.state == .unavailable)
    #expect(host.errors.count == 1)
    #expect(host.errors.first?.contains("cannot load \(bundle.path)/Contents/Helpers/libNowPlayingBridge.dylib") == true)
    try await Task.sleep(for: .milliseconds(300))
    #expect(!host.logs.contains { $0.1.contains("starting it again") })
    plugin.deactivate()
}

/// The reader delivers every line in order, long ones whole, then the exit status; an unfinished
/// last line is dropped. `stop()` ends a helper that waits on its stdin and one that ignores it.
@MainActor
@Test func R08__line_reader_delivers_lines_in_order_then_the_exit() async throws {
    let script = #"""
    i=0
    while [ $i -lt 200 ]; do echo "line $i"; i=$((i+1)); done
    head -c 300000 /dev/zero | tr '\0' 'x'; echo
    printf 'unfinished'
    exit 3
    """#
    var lines: [String] = []
    var exit: (status: Int32, lines: Int)?
    let process = try LineProcess.start(
        HelperCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script]),
        onLine: { lines.append($0) },
        onExit: { exit = ($0, lines.count) }
    )
    await waitUntil { exit != nil }
    #expect(exit?.status == 3)
    #expect(exit?.lines == 201)
    #expect(Array(lines.prefix(200)) == (0..<200).map { "line \($0)" })
    #expect(lines.last == String(repeating: "x", count: 300_000))
    process.stop()

    for (executable, arguments) in [("/bin/cat", [String]()), ("/bin/sleep", ["30"])] {
        var ended = false
        let waiting = try LineProcess.start(
            HelperCommand(executable: URL(fileURLWithPath: executable), arguments: arguments),
            onLine: { _ in },
            onExit: { _ in ended = true }
        )
        let start = ContinuousClock.now
        waiting.stop()
        #expect(ContinuousClock.now - start < .seconds(2), "\(executable)")
        await waitUntil { ended }
        #expect(ended, "\(executable)")
    }
}
