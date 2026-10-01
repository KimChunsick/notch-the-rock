import AppKit
import Foundation
import NotchKit
import os
import SwiftUI
@testable import NowPlaying

/// Records what the plugin posts, clears and logs.
@MainActor
final class RecordingHost: NotchHost {
    enum Event: Equatable {
        case post(id: String, priority: Int)
        case clear(id: String)
    }

    private(set) var events: [Event] = []
    private(set) var logs: [(LogLevel, String)] = []

    func post(_ activity: LiveActivity, from pluginID: String) {
        events.append(.post(id: activity.id, priority: activity.priority))
    }

    func clearActivity(id: String, from pluginID: String) {
        events.append(.clear(id: id))
    }

    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}

    func log(_ level: LogLevel, _ message: String, from pluginID: String) {
        logs.append((level, message))
    }

    var errors: [String] { logs.filter { $0.0 == .error }.map(\.1) }
}

@MainActor
func makeContext(host: RecordingHost, bundleURL: URL = URL(fileURLWithPath: "/nonexistent")) throws -> NotchContext {
    let id = NowPlayingPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("nowplaying-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "nowplaying-tests.\(id)",
        keychainService: "nowplaying-tests.\(id)"
    )
    return NotchContext(pluginID: id, bundleURL: bundleURL, host: host, storage: storage)
}

/// A stream helper the test drives: it prints the lines and exits when told.
@MainActor
final class FakeStream: StreamHandle {
    private let onLine: @MainActor (String) -> Void
    private let onExit: @MainActor (Int32) -> Void
    private(set) var isStopped = false

    init(onLine: @escaping @MainActor (String) -> Void, onExit: @escaping @MainActor (Int32) -> Void) {
        self.onLine = onLine
        self.onExit = onExit
    }

    func emit(_ line: String) { onLine(line) }
    func exit(_ status: Int32) { onExit(status) }
    func stop() { isStopped = true }
}

@MainActor
final class FakeLauncher: HelperLauncher {
    private(set) var streams: [FakeStream] = []
    private(set) var sent: [NowPlayingCommand] = []
    var startError: (any Error)?
    var sendResult: Result<Int32, any Error> = .success(0)

    func startStream(
        onLine: @escaping @MainActor (String) -> Void,
        onExit: @escaping @MainActor (Int32) -> Void
    ) throws -> any StreamHandle {
        if let startError { throw startError }
        let stream = FakeStream(onLine: onLine, onExit: onExit)
        streams.append(stream)
        return stream
    }

    func send(_ command: NowPlayingCommand, completion: @escaping @MainActor (Result<Int32, any Error>) -> Void) {
        sent.append(command)
        completion(sendResult)
    }
}

/// A clock whose time moves only when told. Each sleep is recorded; it jumps straight to its
/// deadline, or, while `parksSleeps` is on, waits in a real sleep until its task is cancelled.
final class VirtualClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration

        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleeps: [Swift.Duration] = []
        var parksSleeps = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Swift.Duration { .zero }
    var sleeps: [Swift.Duration] { state.withLock { $0.sleeps } }

    var parksSleeps: Bool {
        get { state.withLock { $0.parksSleeps } }
        set { state.withLock { $0.parksSleeps = newValue } }
    }

    func advance(by duration: Swift.Duration) {
        state.withLock { $0.now = $0.now.advanced(by: duration) }
    }

    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        let park = state.withLock { state in
            state.sleeps.append(state.now.duration(to: deadline))
            if !state.parksSleeps { state.now = max(state.now, deadline) }
            return state.parksSleeps
        }
        if park { try await Task.sleep(for: .seconds(3600)) }
    }
}

/// Lets queued main-actor work run until `condition` holds or five seconds pass.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

/// One `info` line as the helper writes it.
func infoLine(
    title: String = "Blue in Green",
    artist: String? = "Miles Davis",
    album: String? = "Kind of Blue",
    duration: Double? = 337.5,
    elapsed: Double? = 12,
    timestamp: Double = 1_790_000_000,
    rate: Double? = 1,
    playing: Bool = true,
    bundleID: String? = "com.apple.Music",
    artwork: Any? = nil
) -> String {
    var object: [String: Any] = ["type": "info", "title": title, "timestamp": timestamp, "playing": playing]
    object["artist"] = artist
    object["album"] = album
    object["duration"] = duration
    object["elapsed"] = elapsed
    object["rate"] = rate
    object["bundleID"] = bundleID
    object["artwork"] = artwork
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// The `artwork` value of a line carrying `data`.
func artworkObject(_ data: Data, mime: String = "image/png") -> [String: Any] {
    ["mime": mime, "data": data.base64EncodedString()]
}

/// A PNG of a diagonal gradient, like a small album cover.
func samplePNG(side: Int = 120, hue: Double = 0.6) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    for y in 0..<side {
        for x in 0..<side {
            let t = Double(x + y) / Double(2 * side)
            rep.setColor(NSColor(deviceHue: (hue + 0.25 * t).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.95 - 0.4 * t, alpha: 1), atX: x, y: y)
        }
    }
    return rep.representation(using: .png, properties: [:])!
}
