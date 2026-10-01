import Foundation
import NotchKit
import SwiftUI

/// Shows what the system is playing (Music, Spotify, a browser…): the album art and moving bars
/// beside the collapsed notch, the item with its progress and the transport buttons in the expanded
/// notch, and a home tile.
///
/// MediaRemote answers only Apple's own processes, so the plugin reads it through a helper:
/// `/usr/bin/perl` loading the plugin's `libNowPlayingBridge.dylib` (see NowPlayingBridge.h). One
/// helper streams the state while the plugin is active and is started again, with a growing delay,
/// when it ends unexpectedly. A helper that reports MediaRemote unavailable is not started again
/// until the next activation: it would get the same answer. Each button press runs a short helper
/// that sends the command.
@MainActor
public final class NowPlayingPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.nowplaying",
        name: "지금 재생 중",
        version: "1.0.0",
        symbol: "music.note",
        sdkVersion: NotchKitSDK.version
    )

    static let activityID = "now-playing"
    /// Live activity priority while something plays: something the user is doing, as the docs say.
    static let playingPriority = 100
    /// Paused, the item stays beside the notch as ambient information.
    static let pausedPriority = 0

    let model = NowPlayingModel()
    private let context: NotchContext
    private let launcher: any HelperLauncher
    /// Waits on the plugin's clock; throws when the waiting task is cancelled.
    private let wait: @Sendable (Duration) async throws -> Void
    /// Starts measuring on the plugin's clock; the returned closure tells the time since.
    private let startStopwatch: @MainActor () -> @MainActor () -> Duration

    private var isActive = false
    private var stream: (any StreamHandle)?
    /// Counts started helpers; output of an earlier one is ignored.
    private var generation = 0
    private var runningTime: (@MainActor () -> Duration)?
    private var backoff = RestartBackoff()
    private var restartTask: Task<Void, Never>?
    /// Priority of the posted live activity, nil while none is posted.
    private var postedPriority: Int?

    public convenience init(context: NotchContext) {
        let library = context.bundleURL.appendingPathComponent(HelperCommand.libraryPath)
        self.init(context: context, launcher: PerlHelperLauncher(library: library), clock: ContinuousClock())
    }

    init<C: Clock<Duration>>(context: NotchContext, launcher: any HelperLauncher, clock: C) {
        self.context = context
        self.launcher = launcher
        wait = { try await clock.sleep(for: $0) }
        startStopwatch = {
            let start = clock.now
            return { start.duration(to: clock.now) }
        }
    }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        backoff = RestartBackoff()
        startStream()
    }

    public func deactivate() {
        guard isActive else { return }
        isActive = false
        restartTask?.cancel()
        restartTask = nil
        generation += 1
        stream?.stop()
        stream = nil
        model.reset()
        updateActivity()
    }

    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [model] in
            NowPlayingView(model: model) { [weak self] in self?.send($0) }
        }
    }

    /// Wide: art, title, artist and play/pause. Small: art and play/pause.
    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.wide, .small]) { [model] size in
            NowPlayingTile(model: model, size: size) { [weak self] in self?.send($0) }
        }
    }

    /// Asks the playing app to carry out `command`. The stream reports the result.
    func send(_ command: NowPlayingCommand) {
        launcher.send(command) { [context] result in
            switch result {
            case .success(0):
                break
            case .success(let status):
                context.log.error("The Now Playing helper could not send \(command.rawValue) (exit status \(status)).")
            case .failure(let error):
                context.log.error("The Now Playing helper could not start to send \(command.rawValue): \(error)")
            }
        }
    }

    private func startStream() {
        generation += 1
        let current = generation
        do {
            stream = try launcher.startStream(
                onLine: { [weak self] line in self?.receive(line, from: current) },
                onExit: { [weak self] status in self?.streamEnded(status, from: current) }
            )
            runningTime = startStopwatch()
        } catch {
            // Without /usr/bin/perl there is no other way to MediaRemote.
            refuse("could not start /usr/bin/perl: \(error)")
        }
    }

    private func receive(_ line: String, from helper: Int) {
        guard helper == generation else { return }
        guard let parsed = HelperLine(line) else {
            context.log.debug("Ignored a Now Playing helper line that is not in its format.")
            return
        }
        if case .unavailable(let reason) = parsed {
            refuse(reason)
            return
        }
        model.apply(parsed)
        updateActivity()
    }

    /// Shows the quiet unavailable state; the helper is not started again in this activation.
    private func refuse(_ reason: String) {
        context.log.error("Now Playing is unavailable: \(reason)")
        model.apply(.unavailable(reason: reason))
        updateActivity()
    }

    private func streamEnded(_ status: Int32, from helper: Int) {
        guard helper == generation else { return }
        stream = nil
        guard model.state != .unavailable else { return }
        model.reset()
        updateActivity()
        let delay = backoff.delay(afterRunOf: runningTime?() ?? .zero)
        context.log.info("The Now Playing helper ended (exit status \(status)); starting it again in \(delay).")
        restartTask = Task { [weak self, wait] in
            do { try await wait(delay) } catch { return }
            self?.restart()
        }
    }

    private func restart() {
        restartTask = nil
        guard isActive, stream == nil else { return }
        startStream()
    }

    /// Posts the wings while an item is playing or paused and clears them when nothing is. The
    /// posted views follow the model, so a new post is needed only when the priority changes.
    private func updateActivity() {
        let priority: Int? = model.track.map { $0.isPlaying ? Self.playingPriority : Self.pausedPriority }
        guard priority != postedPriority else { return }
        if let priority {
            context.post(LiveActivity(id: Self.activityID, priority: priority) { [model] in
                NowPlayingWings.Leading(model: model)
            } trailing: { [model] in
                NowPlayingWings.Trailing(model: model)
            })
        } else {
            context.clear(activityID: Self.activityID)
        }
        postedPriority = priority
    }
}

/// The delay before starting a helper again that ended unexpectedly: 1 s, doubling after each run
/// shorter than `stableRun`, up to 30 s. A run of at least `stableRun` starts over at 1 s.
struct RestartBackoff {
    static let first: Duration = .seconds(1)
    static let longest: Duration = .seconds(30)
    static let stableRun: Duration = .seconds(30)

    private var shortRuns = 0

    mutating func delay(afterRunOf run: Duration) -> Duration {
        if run >= Self.stableRun {
            shortRuns = 0
        }
        let delay = min(Self.first * (1 << min(shortRuns, 5)), Self.longest)
        shortRuns += 1
        return delay
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(NowPlayingPlugin.self)
}
