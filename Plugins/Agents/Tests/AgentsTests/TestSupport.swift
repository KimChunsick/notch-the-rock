import AppKit
import Foundation
import HookBridge
import NotchKit
import os
import SwiftUI
import Testing
@testable import Agents

/// Records what the plugin asks of the notch and answers each attention request with the next of
/// `responses` (`.dismissed` once they run out). With `waitsForCancellation` it answers only when
/// the asking task is cancelled, as the host does when a request is withdrawn.
@MainActor
final class FakeHost: NotchHost {
    var responses: [AttentionResponse] = []
    var waitsForCancellation = false
    var requests: [AttentionRequest] = []
    /// Requests withdrawn by cancelling the task that asked.
    var cancellations = 0
    var expansions = 0
    var collapses = 0
    var logs: [String] = []

    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse {
        requests.append(request)
        if waitsForCancellation {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            cancellations += 1
            return .cancelled
        }
        return responses.isEmpty ? .dismissed : responses.removeFirst()
    }
    func expand(toTabOf pluginID: String) { expansions += 1 }
    func collapse(from pluginID: String) { collapses += 1 }
    var isAccessibilityTrusted: Bool { true }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) { logs.append(message) }
}

@MainActor
final class FakeActivator: TerminalActivating {
    var activated: [TerminalLocation] = []
    var succeeds = true

    func activate(_ terminal: TerminalLocation) -> Bool {
        activated.append(terminal)
        return succeeds
    }
}

/// Plugin storage in `directory`. The defaults suite is named by an absolute path, so its plist is
/// written inside the temporary folder rather than ~/Library/Preferences; the keychain is not used.
@MainActor
func makeContext(host: FakeHost, directory: URL) throws -> NotchContext {
    let storage = try PluginStorage(
        directory: directory,
        defaultsSuiteName: isolatedDefaultsSuite(in: directory),
        keychainService: "com.notchtherock.agents.tests.\(UUID().uuidString)"
    )
    return NotchContext(pluginID: AgentsPlugin.manifest.id, bundleURL: directory, host: host, storage: storage)
}

/// A defaults suite stored as `defaults.plist` in `directory`, never in the app's or the user's
/// defaults.
func isolatedDefaultsSuite(in directory: URL) -> String {
    directory.appendingPathComponent("defaults").path
}

/// A fresh folder in the temporary directory.
func makeDirectory(_ name: String = "agents-tests") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// A socket path short enough for `sockaddr_un` (104 bytes) in a folder that does not exist yet.
func makeSocketPath() -> (folder: String, socket: String) {
    let folder = "/tmp/nk-\(UUID().uuidString.prefix(8))"
    return (folder, folder + "/s")
}

/// The package folder, found from this file's path.
let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The `notch-hook` that `swift test` built next to the tests.
let builtHook = packageRoot.appendingPathComponent(".build/debug/notch-hook")

/// What a process wrote and how it ended.
struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let elapsed: Duration
}

/// Runs `executable` with `arguments`, feeding `input` on stdin, and waits for it to exit.
func runProcess(_ executable: URL, _ arguments: [String], input: Data, environment: [String: String]) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    let clock = ContinuousClock()
    let start = clock.now
    try process.run()
    stdin.fileHandleForWriting.write(input)
    try stdin.fileHandleForWriting.close()
    let out = stdout.fileHandleForReading.readDataToEndOfFile()
    let err = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ProcessResult(status: process.terminationStatus, stdout: out, stderr: err, elapsed: clock.now - start)
}

/// Messages a test server received, collected across threads.
final class Inbox: Sendable {
    private let messages = OSAllocatedUnfairLock(initialState: [HookMessage]())

    func append(_ message: HookMessage) {
        messages.withLock { $0.append(message) }
    }

    var all: [HookMessage] { messages.withLock { $0 } }

    /// Waits up to two seconds until at least `count` messages arrived.
    func wait(for count: Int) async -> [HookMessage] {
        for _ in 0..<200 where all.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return all
    }
}

/// Parses `data` as a JSON object for comparisons that ignore key order and formatting.
func jsonObject(_ data: Data) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

/// Writes a render of `view` to `$AGENTS_CAPTURE_DIR/<name>.png` when that variable is set. The view
/// is drawn by an offscreen hosting view, so AppKit-backed controls (forms, buttons) appear too.
@MainActor
func capture(_ view: some View, named name: String) throws {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    hosting.appearance = NSAppearance(named: .darkAqua)
    hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
    hosting.layoutSubtreeIfNeeded()
    try capture(hosting, named: name)
}

/// Writes a render of a laid-out `hosting` view to `$AGENTS_CAPTURE_DIR/<name>.png` when that
/// variable is set.
@MainActor
func capture(_ hosting: NSView, named name: String) throws {
    guard let directory = ProcessInfo.processInfo.environment["AGENTS_CAPTURE_DIR"] else { return }
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let png = try #require(rep.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
}

/// `view` on black in an offscreen hosting view of exactly `size`, laid out as a host that offers
/// that size lays it out. Whatever falls outside the hosting view's bounds is not visible.
@MainActor
func layOut(_ view: some View, in size: CGSize) -> NSView {
    let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.black).environment(\.colorScheme, .dark))
    hosting.appearance = NSAppearance(named: .darkAqua)
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    return hosting
}

/// The AppKit buttons and text fields in `root` outside any scroll view (they stay where they are
/// while the body scrolls), and the scroll views, framed in `root`'s coordinates.
@MainActor
func pinnedControls(in root: NSView) -> (controls: [(control: NSControl, frame: CGRect)], scrollViews: [CGRect]) {
    var controls: [(control: NSControl, frame: CGRect)] = []
    var scrollViews: [CGRect] = []
    func walk(_ view: NSView) {
        if view is NSScrollView {
            scrollViews.append(view.convert(view.bounds, to: root))
            return
        }
        if let control = view as? NSControl, control is NSButton || control is NSTextField {
            controls.append((control, control.convert(control.bounds, to: root)))
            return
        }
        view.subviews.forEach(walk)
    }
    walk(root)
    return (controls, scrollViews)
}
