import AppKit
import CryptoKit
import Darwin
import Foundation
import NotchKit
import os
import Testing
@testable import Clipboard

/// Opens the history the way the plugin does, from the key file in the directory, and records for
/// every opening whether it ran on the main thread. While `isHeld` is on, an opening waits, like a
/// slow disk; while `fails` is on, it throws before reading anything, like a read error.
final class OpeningGate: Sendable {
    private struct State {
        var isHeld = false
        var fails = false
        var onMain: [Bool] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isHeld: Bool {
        get { state.withLock { $0.isHeld } }
        set { state.withLock { $0.isHeld = newValue } }
    }

    var fails: Bool {
        get { state.withLock { $0.fails } }
        set { state.withLock { $0.fails = newValue } }
    }

    /// For every opening that got past the wait, whether it ran on the main thread.
    var onMain: [Bool] { state.withLock { $0.onMain } }

    func open(_ directory: URL) throws -> ClipboardStore.Opened {
        let onMain = Thread.isMainThread
        while isHeld {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let fails = state.withLock { state in
            state.onMain.append(onMain)
            return state.fails
        }
        if fails { throw CocoaError(.fileReadUnknown) }
        return try ClipboardStore.open(in: directory)
    }
}

private func bytes(of key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

private func keyFile(in directory: URL) -> URL {
    directory.appendingPathComponent(HistoryKey.fileName)
}

/// The key in the key file, read as plain bytes.
private func storedKey(in directory: URL) throws -> SymmetricKey {
    SymmetricKey(data: try Data(contentsOf: keyFile(in: directory)))
}

/// The list on disk, opened with the key in the key file.
private func storedContents(in directory: URL) throws -> [ClipItem.Content] {
    try ClipboardStore(directory: directory, key: storedKey(in: directory)).loadList().map(\.content)
}

/// The `lstat` of `url`: the entry itself, never what a symlink points to.
private func entryStatus(_ url: URL) throws -> stat {
    var info = stat()
    try #require(lstat(url.path, &info) == 0, "no entry at \(url.path)")
    return info
}

/// A history in `directory` written with `key`, one text entry.
@MainActor
private func writeHistory(in directory: URL, key: SymmetricKey, text: String) {
    let history = makeHistory(directory: directory, key: key)
    history.record(.text(text))
    history.flush()
}

/// A history from before the key file: sealed with a key that was kept elsewhere (the keychain),
/// a text and an image, with the empty marker a key replacement left when `withMarker` is set.
@MainActor
private func writeHistoryFromBeforeTheKeyFile(in directory: URL, withMarker: Bool = false) throws {
    let history = makeHistory(directory: directory, key: makeKey())
    history.record(.text("sealed with the keychain key"))
    history.record(try #require(ClipCapture(png: samplePNG(seed: 5))))
    history.flush()
    if withMarker {
        try Data().write(to: directory.appendingPathComponent(ClipboardStore.oldHistoryMarkerName))
    }
}

@MainActor
private final class LogHost: NotchHost {
    var logs: [(LogLevel, String)] = []
    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) { logs.append((level, message)) }
}

/// The plugin with its storage folder at `directory`, opening through `gate`, and a private
/// pasteboard. Each call builds a new `PluginStorage`, as a new process would.
@MainActor
private func makePlugin(directory: URL, gate: OpeningGate = OpeningGate(), pasteboard: NSPasteboard, host: LogHost = LogHost()) throws -> ClipboardPlugin {
    let id = ClipboardPlugin.manifest.id
    let storage = try PluginStorage(directory: directory, defaultsSuiteName: "clipboard-tests.\(id)", keychainService: "clipboard-tests.\(id)")
    return ClipboardPlugin(
        context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage),
        pasteboard: pasteboard,
        openStore: { try gate.open($0) }
    )
}

/// Puts `text` on `pasteboard` as a new copy.
private func put(_ text: String, on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}

// MARK: - The key file

/// The first opening creates the key file in the plugin's storage folder: a regular file of this
/// user, mode 0600, holding the 256-bit key. Later openings use the key in it.
@MainActor
@Test func R57__the_key_file_is_created_0600_in_the_storage_folder() async throws {
    let directory = try makeDirectory()
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    put("copied before the key file existed", on: pasteboard)
    let plugin = try makePlugin(directory: directory, pasteboard: pasteboard)

    plugin.activate()
    await plugin.opening?.value
    plugin.deactivate()

    let info = try entryStatus(keyFile(in: directory))
    #expect(info.st_mode & S_IFMT == S_IFREG)
    #expect(info.st_mode & 0o7777 == 0o600)
    #expect(info.st_uid == geteuid())
    #expect(info.st_size == 32)
    #expect(try storedContents(in: directory) == [.text("copied before the key file existed")])

    let key = try storedKey(in: directory)
    let again = try ClipboardStore.open(in: directory)
    #expect(again.origin == .stored)
    #expect(bytes(of: again.key) == bytes(of: key))
}

/// A new plugin instance over a new `PluginStorage` of the same folder, as after a restart or a
/// reinstall, opens the history the first one saved, with the same key, and leaves the key file as
/// it was.
@MainActor
@Test func R57__a_new_plugin_instance_opens_the_same_history_with_the_same_key() async throws {
    let directory = try makeDirectory()
    let first = makePasteboard()
    defer { first.releaseGlobally() }
    put("copied in the first session", on: first)
    let plugin = try makePlugin(directory: directory, pasteboard: first)
    plugin.activate()
    await plugin.opening?.value
    plugin.deactivate()
    let keyBytes = try Data(contentsOf: keyFile(in: directory))
    let created = try entryStatus(keyFile(in: directory))

    let second = makePasteboard()
    defer { second.releaseGlobally() }
    put("copied in the second session", on: second)
    let reopened = try makePlugin(directory: directory, pasteboard: second)
    reopened.activate()
    await reopened.opening?.value
    reopened.deactivate()

    let expected: [ClipItem.Content] = [.text("copied in the second session"), .text("copied in the first session")]
    #expect(reopened.history.items.map(\.content) == expected)
    #expect(try storedContents(in: directory) == expected)
    #expect(try Data(contentsOf: keyFile(in: directory)) == keyBytes)
    #expect(try entryStatus(keyFile(in: directory)).st_ino == created.st_ino)
}

/// A key file that is not a private regular file of this user is never used: readable by others,
/// a symlink (even to a private file holding the right key) or a directory. A new key file
/// replaces it, and the history sealed with the distrusted key starts over; a symlink's target is
/// left alone.
@MainActor
@Test(arguments: ["readable by others", "symlink", "directory"])
func R57__a_key_file_that_is_not_a_private_regular_file_is_not_trusted(_ tampering: String) throws {
    let directory = try makeDirectory()
    let key = try ClipboardStore.open(in: directory).key
    writeHistory(in: directory, key: key, text: "sealed with the distrusted key")
    let file = keyFile(in: directory)
    let elsewhere = try makeDirectory().appendingPathComponent("planted.key")
    switch tampering {
    case "readable by others":
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    case "symlink":
        try bytes(of: key).write(to: elsewhere)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: elsewhere.path)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
    default:
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    }

    let opened = try ClipboardStore.open(in: directory)

    #expect(opened.origin == .replacedUntrustedFile)
    #expect(opened.removedOldHistory)
    #expect(bytes(of: opened.key) != bytes(of: key))
    let info = try entryStatus(file)
    #expect(info.st_mode & S_IFMT == S_IFREG)
    #expect(info.st_mode & 0o7777 == 0o600)
    #expect(bytes(of: try storedKey(in: directory)) == bytes(of: opened.key))
    #expect(try files(in: directory).map(\.lastPathComponent) == [HistoryKey.fileName])
    if tampering == "symlink" {
        #expect(try Data(contentsOf: elsewhere) == bytes(of: key))
    }
    let again = try ClipboardStore.open(in: directory)
    #expect(again.origin == .stored)
    #expect(!again.removedOldHistory)
}

/// Every file the plugin leaves in its folder, the key file included, is read byte by byte: the
/// copied text appears in none of them.
@MainActor
@Test func R57__the_stored_files_hold_no_plaintext() async throws {
    let directory = try makeDirectory()
    let text = "R57-plaintext-marker-\(UUID().uuidString)"
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    put("비밀 메모 \(text)", on: pasteboard)
    let plugin = try makePlugin(directory: directory, pasteboard: pasteboard)
    plugin.activate()
    await plugin.opening?.value
    plugin.deactivate()

    let stored = try contents(of: directory)
    #expect(Set(stored.keys) == [HistoryKey.fileName, ClipboardStore.listFileName])
    for needle in [Data(text.utf8), try #require(text.data(using: .utf16LittleEndian))] {
        for (name, data) in stored {
            #expect(data.range(of: needle) == nil, "\(name) holds the copied text")
        }
    }
    #expect(try storedContents(in: directory) == [.text("비밀 메모 \(text)")])
}

/// A history from before the key file, sealed with the key the keychain kept, cannot be opened
/// with the new key: the first opening starts a new history and removes the old files, whether or
/// not a key replacement left its marker. Later openings keep the new history.
@MainActor
@Test(arguments: [false, true])
func R57__a_history_from_before_the_key_file_starts_a_new_history_once(withMarker: Bool) throws {
    let directory = try makeDirectory()
    try writeHistoryFromBeforeTheKeyFile(in: directory, withMarker: withMarker)
    #expect(try files(in: directory).count == (withMarker ? 3 : 2))

    let opened = try ClipboardStore.open(in: directory)
    #expect(opened.origin == .created)
    #expect(opened.removedOldHistory)
    #expect(try files(in: directory).map(\.lastPathComponent) == [HistoryKey.fileName])

    let history = ClipboardHistory(logError: { _ in })
    history.open(opened.store)
    #expect(!history.isStoreUnreadable)
    history.record(.text("copied after the new key"))
    history.flush()

    let reopened = try ClipboardStore.open(in: directory)
    #expect(reopened.origin == .stored)
    #expect(!reopened.removedOldHistory)
    #expect(try storedContents(in: directory) == [.text("copied after the new key")])
}

/// Removing the old history fails after the new key file is in place: the next opening removes it
/// once the disk allows it, and new copies are saved again.
@MainActor
@Test func R57__an_old_history_that_could_not_be_removed_is_removed_next_time() throws {
    let directory = try makeDirectory()
    try writeHistoryFromBeforeTheKeyFile(in: directory)
    let list = directory.appendingPathComponent(ClipboardStore.listFileName).path
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: list)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: list) }

    #expect(throws: (any Error).self) { try ClipboardStore.open(in: directory) }
    let key = try storedKey(in: directory)
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: list)

    let opened = try ClipboardStore.open(in: directory)
    #expect(opened.origin == .stored)
    #expect(opened.removedOldHistory)
    #expect(bytes(of: opened.key) == bytes(of: key))
    #expect(try files(in: directory).map(\.lastPathComponent) == [HistoryKey.fileName])
}

/// A marker left beside a history that the key file's key opens (a run that stopped after the
/// new history was written, before the marker went) never deletes that history; only the marker
/// goes.
@MainActor
@Test func R57__a_stale_marker_never_deletes_a_history_the_key_opens() throws {
    let directory = try makeDirectory()
    let key = try ClipboardStore.open(in: directory).key
    writeHistory(in: directory, key: key, text: "readable with the key")
    let marker = directory.appendingPathComponent(ClipboardStore.oldHistoryMarkerName)
    try Data().write(to: marker)

    let opened = try ClipboardStore.open(in: directory)
    #expect(opened.origin == .stored)
    #expect(!opened.removedOldHistory)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(try storedContents(in: directory) == [.text("readable with the key")])
}

/// The plugin's sources make no keychain call of any kind: no Security framework keychain symbol
/// and none of NotchKit's keychain methods.
@Test func R57__the_clipboard_sources_make_no_keychain_calls() throws {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Clipboard")
    let swiftFiles = try files(in: sources).filter { $0.pathExtension == "swift" }
    #expect(swiftFiles.count > 5)
    let symbols = [
        "import Security", "SecItem", "SecKeychain", "SecAccess", "kSecClass",
        "keychainData", "setKeychainData", "deleteKeychainData", "KeychainError", "KeychainAccess", ".keychain",
    ]
    for file in swiftFiles {
        let source = try String(contentsOf: file, encoding: .utf8)
        for symbol in symbols {
            #expect(!source.contains(symbol), "\(file.lastPathComponent) uses \(symbol)")
        }
    }
}

// MARK: - Copies while the history opens

/// `activate()` returns at once and the history stays empty while the opening waits; the key file
/// is never read on the main thread. A new history that replaces an unreadable one is logged at
/// info level, and copies are recorded once the history is open.
@MainActor
@Test func R09__the_plugin_never_opens_the_history_on_the_main_thread() async throws {
    let directory = try makeDirectory()
    try writeHistoryFromBeforeTheKeyFile(in: directory)
    let gate = OpeningGate()
    gate.isHeld = true
    let host = LogHost()
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = try makePlugin(directory: directory, gate: gate, pasteboard: pasteboard, host: host)

    plugin.activate()
    #expect(plugin.history.items.isEmpty)
    gate.isHeld = false
    await plugin.opening?.value

    #expect(gate.onMain == [false])
    #expect(host.logs.contains { $0.0 == .info && $0.1.contains("new clipboard history") }, "\(host.logs)")
    #expect(try files(in: directory).map(\.lastPathComponent) == [HistoryKey.fileName])

    put("copied after opening", on: pasteboard)
    try await Task.sleep(for: PasteboardMonitor.interval * 3)
    plugin.deactivate()
    #expect(plugin.history.items.map(\.content) == [.text("copied after opening")])
    #expect(try storedContents(in: directory) == [.text("copied after opening")])
}

/// Copies made while the history opens are kept and recorded once it is open, oldest first, by
/// the same rules as any copy: a repeat moves the stored entry to the top. Then they are saved.
@MainActor
@Test func R09__copies_made_while_the_key_loads_are_recorded_once_the_history_opens() async throws {
    let directory = try makeDirectory()
    let stored = makeHistory(directory: directory, key: try ClipboardStore.open(in: directory).key)
    stored.record(.text("from the last session"))
    stored.record(.text("copied again"))
    stored.flush()
    let gate = OpeningGate()
    gate.isHeld = true
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = try makePlugin(directory: directory, gate: gate, pasteboard: pasteboard)

    plugin.activate()
    for text in ["copied again", "copied while the key loads"] {
        put(text, on: pasteboard)
        try await Task.sleep(for: PasteboardMonitor.interval * 3)
    }
    gate.isHeld = false
    await plugin.opening?.value
    plugin.deactivate()

    let expected: [ClipItem.Content] = [.text("copied while the key loads"), .text("copied again"), .text("from the last session")]
    #expect(plugin.history.items.map(\.content) == expected)
    #expect(try storedContents(in: directory) == expected)
}

/// What the pasteboard holds when the plugin starts is recorded like a new copy.
@MainActor
@Test func R09__the_item_on_the_pasteboard_at_activation_is_recorded() async throws {
    let directory = try makeDirectory()
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    put("copied before the plugin started", on: pasteboard)
    let plugin = try makePlugin(directory: directory, pasteboard: pasteboard)

    plugin.activate()
    await plugin.opening?.value
    plugin.deactivate()

    #expect(plugin.history.items.map(\.content) == [.text("copied before the plugin started")])
    #expect(try storedContents(in: directory) == [.text("copied before the plugin started")])
}

/// Whether `history` lists `content` within a second of this call, the time R09 gives a copy to
/// show, on the monotonic clock with nothing discounted: an entry seen only after the deadline does
/// not count. Call it right after the copy, in `MainActorTimingTests` after
/// `waitForAQuietMainActor()`, so other tests holding the main actor do not run meanwhile.
@MainActor
private func showsWithinASecond(_ content: ClipItem.Content, in history: ClipboardHistory) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(1)
    while true {
        let shows = history.items.contains { $0.content == content }
        // The clock is read after looking, so a hit counts only if it was there by the deadline.
        guard ContinuousClock.now <= deadline else { return false }
        if shows { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

extension MainActorTimingTests {
    /// However long the history takes to open, a copy shows in the list within a second, and it is
    /// saved once the history opens.
    @MainActor
    @Test func R09__a_copy_shows_within_a_second_while_the_key_loads() async throws {
        let directory = try makeDirectory()
        let gate = OpeningGate()
        gate.isHeld = true
        defer { gate.isHeld = false }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let plugin = try makePlugin(directory: directory, gate: gate, pasteboard: pasteboard)

        await waitForAQuietMainActor()
        plugin.activate()
        put("copied while the key loads", on: pasteboard)
        #expect(await showsWithinASecond(.text("copied while the key loads"), in: plugin.history))
        #expect(gate.onMain.isEmpty, "the key is still loading")

        gate.isHeld = false
        await plugin.opening?.value
        plugin.deactivate()
        #expect(plugin.history.items.map(\.content) == [.text("copied while the key loads")])
        #expect(try storedContents(in: directory) == [.text("copied while the key loads")])
    }
}

extension MainActorTimingTests {
    /// Turning the feature off while the history opens loses no copy made meanwhile: turned on
    /// again, the history opens with every one of them, newest first, and saves them.
    @MainActor
    @Test func R09__copies_survive_turning_off_while_the_key_loads() async throws {
        let directory = try makeDirectory()
        let gate = OpeningGate()
        gate.isHeld = true
        defer { gate.isHeld = false }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let plugin = try makePlugin(directory: directory, gate: gate, pasteboard: pasteboard)

        await waitForAQuietMainActor()
        plugin.activate()
        for text in ["copy A", "copy B"] {
            put(text, on: pasteboard)
            #expect(await showsWithinASecond(.text(text), in: plugin.history))
        }
        plugin.deactivate()
        gate.isHeld = false
        plugin.activate()
        await plugin.opening?.value
        plugin.deactivate()

        let expected: [ClipItem.Content] = [.text("copy B"), .text("copy A")]
        #expect(plugin.history.items.map(\.content) == expected)
        #expect(try storedContents(in: directory) == expected)
    }
}

/// SplitMix64, so a seed always gives the same session.
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

/// What is on disk when a random session starts.
private enum SessionStart: CaseIterable {
    case firstRun, historyFromBeforeTheKeyFile, historyFromBeforeTheKeyFileWithMarker, staleMarkerOnReadableHistory
}

/// How the opening goes: waiting, as a slow disk would, answering, or failing like a read error.
private enum KeyState {
    case held, healthy, failing
}

private enum SessionStep {
    case copy, activate, deactivate, holdKey, releaseKey, failKey, reopen
}

private func apply(_ state: KeyState, to gate: OpeningGate) {
    gate.fails = state == .failing
    gate.isHeld = state == .held
}

extension MainActorTimingTests {
    /// Random sessions from fixed seeds: copies, turning the feature off and on, and an opening that
    /// waits or fails. After each copy it must show within a second; once the opening answers again
    /// and the history opens: every copy is listed and saved, newest first; a history that the key
    /// file's key opens was never deleted, one from before the key file was; no marker is left; and
    /// no opening ran on the main thread.
    @MainActor
    @Test func R09__random_sessions_keep_every_copy_and_every_readable_history() async throws {
        for seed in UInt64(1)...12 {
            try await runRandomSession(seed: seed)
        }
    }
}

@MainActor
private func runRandomSession(seed: UInt64) async throws {
    var random = SeededGenerator(state: seed)
    let start = SessionStart.allCases[Int(seed % UInt64(SessionStart.allCases.count))]
    let directory = try makeDirectory()
    let marker = directory.appendingPathComponent(ClipboardStore.oldHistoryMarkerName)
    let gate = OpeningGate()
    defer { gate.isHeld = false }
    switch start {
    case .firstRun:
        break
    case .historyFromBeforeTheKeyFile, .historyFromBeforeTheKeyFileWithMarker:
        writeHistory(in: directory, key: makeKey(), text: "from before")
        if start == .historyFromBeforeTheKeyFileWithMarker { try Data().write(to: marker) }
    case .staleMarkerOnReadableHistory:
        writeHistory(in: directory, key: try ClipboardStore.open(in: directory).key, text: "from before")
        try Data().write(to: marker)
    }
    // Even seeds start with an opening that fails, odd seeds with one that waits.
    var keyState: KeyState = seed.isMultiple(of: 2) ? .failing : .held
    apply(keyState, to: gate)
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = try makePlugin(directory: directory, gate: gate, pasteboard: pasteboard)

    await waitForAQuietMainActor()
    var log = ["seed \(seed)", "\(start)", "\(keyState)"]
    var copies: [String] = []
    var isActive = false
    let steps: [SessionStep] = [.copy, .copy, .copy, .activate, .deactivate, .holdKey, .releaseKey, .failKey, .reopen]
    for _ in 0..<18 {
        let step = steps.randomElement(using: &random)!
        log.append("\(step)")
        switch step {
        case .copy where !isActive, .activate where !isActive:
            plugin.activate()
            isActive = true
        case .copy:
            let text = "copy \(seed).\(copies.count)"
            put(text, on: pasteboard)
            copies.append(text)
            let shows = await showsWithinASecond(.text(text), in: plugin.history)
            #expect(shows, Comment(rawValue: "\(text) did not show within a second: \(log)"))
        case .activate:
            break
        case .deactivate:
            if isActive { plugin.deactivate() }
            isActive = false
        case .holdKey, .releaseKey, .failKey:
            let states: [SessionStep: KeyState] = [.holdKey: .held, .releaseKey: .healthy, .failKey: .failing]
            keyState = states[step]!
            apply(keyState, to: gate)
        case .reopen:
            if isActive { plugin.deactivate() }
            plugin.activate()
            isActive = true
        }
        if isActive && keyState != .held {
            await plugin.opening?.value
        }
    }

    // The opening answers again and the feature is turned off and on, so an opening finishes.
    apply(.healthy, to: gate)
    if isActive { plugin.deactivate() }
    plugin.activate()
    await plugin.opening?.value
    plugin.deactivate()

    let comment = Comment(rawValue: log.joined(separator: ", "))
    let copied = copies.reversed().map { ClipItem.Content.text($0) }
    #expect(plugin.history.items.map(\.content).filter { copied.contains($0) } == copied, comment)
    #expect(plugin.history.unsavedCount == 0, comment)
    let stored = try #require(try? storedContents(in: directory), comment)
    #expect(stored == plugin.history.items.map(\.content), comment)
    #expect(!FileManager.default.fileExists(atPath: marker.path), comment)
    if start != .firstRun {
        #expect(stored.contains(.text("from before")) == (start == .staleMarkerOnReadableHistory), comment)
    }
    #expect(gate.onMain.allSatisfy { !$0 }, comment)
}

// MARK: - Edits while the history opens

/// The plugin over a stored history of `stored`, newest first, with `pinned` among them pinned,
/// activated while the history waits to open: copies show, but the stored history is not read yet.
@MainActor
private func activateWhileTheKeyLoads(over stored: [String], pinned: Set<String> = [], pasteboard: NSPasteboard) throws -> (plugin: ClipboardPlugin, gate: OpeningGate, directory: URL) {
    let directory = try makeDirectory()
    let history = makeHistory(directory: directory, key: try ClipboardStore.open(in: directory).key)
    for text in stored.reversed() {
        history.record(.text(text))
    }
    for item in history.items where pinned.contains(item.text ?? "") {
        history.setPinned(true, for: item.id)
    }
    history.flush()
    let gate = OpeningGate()
    gate.isHeld = true
    let plugin = try makePlugin(directory: directory, gate: gate, pasteboard: pasteboard)
    plugin.activate()
    return (plugin, gate, directory)
}

/// Copies `text` and waits until the plugin lists it; how long that takes is the timing tests' job.
@MainActor
private func copy(_ text: String, on pasteboard: NSPasteboard, into plugin: ClipboardPlugin) async throws {
    put(text, on: pasteboard)
    let giveUp = ContinuousClock.now + .seconds(30)
    while !plugin.history.items.contains(where: { $0.content == .text(text) }) {
        try #require(ContinuousClock.now < giveUp, "\(text) never showed")
        try await Task.sleep(for: .milliseconds(20))
    }
}

/// Lets the history open, waits until it is open and turns the feature off.
@MainActor
private func finishOpening(_ plugin: ClipboardPlugin, gate: OpeningGate) async {
    gate.isHeld = false
    await plugin.opening?.value
    plugin.deactivate()
}

/// The entry holding `text`, in the list in memory.
@MainActor
private func entry(_ text: String, in plugin: ClipboardPlugin) throws -> ClipItem {
    try #require(plugin.history.items.first { $0.content == .text(text) })
}

/// A copy deleted while the history opens stays deleted once the stored history, which holds the
/// same text, opens.
@MainActor
@Test func R09__a_copy_deleted_while_the_history_opens_stays_deleted() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let (plugin, gate, directory) = try activateWhileTheKeyLoads(over: ["deleted", "kept"], pasteboard: pasteboard)
    defer { gate.isHeld = false }

    try await copy("deleted", on: pasteboard, into: plugin)
    plugin.history.delete(try entry("deleted", in: plugin).id)
    await finishOpening(plugin, gate: gate)

    #expect(plugin.history.items.map(\.content) == [.text("kept")])
    #expect(try storedContents(in: directory) == [.text("kept")])
}

/// Clearing while the history opens clears the unpinned entries of the stored history too; a
/// pinned one stays, and so does a copy made after the clearing.
@MainActor
@Test func R09__clearing_while_the_history_opens_clears_the_stored_entries_too() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let (plugin, gate, directory) = try activateWhileTheKeyLoads(over: ["stored 1", "pinned", "stored 2"], pinned: ["pinned"], pasteboard: pasteboard)
    defer { gate.isHeld = false }

    try await copy("copied before clearing", on: pasteboard, into: plugin)
    plugin.history.clearUnpinned()
    try await copy("copied after clearing", on: pasteboard, into: plugin)
    await finishOpening(plugin, gate: gate)

    let expected: [ClipItem.Content] = [.text("copied after clearing"), .text("pinned")]
    #expect(plugin.history.items.map(\.content) == expected)
    #expect(try storedContents(in: directory) == expected)
}

/// A pin set or cleared on a copy while the history opens holds once the stored history opens,
/// whatever the stored entry with the same text had; a copy left alone keeps the stored pin.
@MainActor
@Test func R09__pins_set_or_cleared_while_the_history_opens_hold() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let texts = ["pinned now", "unpinned now", "left alone"]
    let (plugin, gate, directory) = try activateWhileTheKeyLoads(over: texts, pinned: ["unpinned now", "left alone"], pasteboard: pasteboard)
    defer { gate.isHeld = false }

    for text in texts.reversed() {
        try await copy(text, on: pasteboard, into: plugin)
    }
    plugin.history.setPinned(true, for: try entry("pinned now", in: plugin).id)
    plugin.history.setPinned(true, for: try entry("unpinned now", in: plugin).id)
    plugin.history.setPinned(false, for: try entry("unpinned now", in: plugin).id)
    await finishOpening(plugin, gate: gate)

    let expected = ["pinned now": true, "unpinned now": false, "left alone": true]
    let pins = Dictionary(uniqueKeysWithValues: plugin.history.items.map { ($0.text ?? "", $0.isPinned) })
    #expect(pins == expected)
    let stored = try ClipboardStore(directory: directory, key: storedKey(in: directory)).loadList()
    #expect(Dictionary(uniqueKeysWithValues: stored.map { ($0.text ?? "", $0.isPinned) }) == expected)
}

extension MainActorTimingTests {
    /// The one-second check measures real time: a copy that shows only after the main actor was
    /// held for one and a half seconds fails it.
    @MainActor
    @Test func R09__the_one_second_check_fails_a_copy_that_shows_after_one_and_a_half_seconds() async {
        let history = ClipboardHistory(logError: { _ in })
        Task { @MainActor in
            usleep(1_500_000)
            history.record(.text("late"))
        }
        #expect(await !showsWithinASecond(.text("late"), in: history))
    }
}
