import AppKit
import CryptoKit
import Foundation
import NotchKit
import os
import Security
import Testing
@testable import Clipboard

/// A keychain in memory that records, for every call, whether it ran on the main thread. Accounts in
/// `needsAccess` fail like an item macOS would ask the user about, and saves under the accounts in
/// `failingSets` fail as given there. While `isHeld` is on, every call waits, like a keychain call
/// waiting on the security daemon.
///
/// `NotchKit` keeps its temporary-keychain switch internal, so this package cannot point a
/// `PluginStorage` at a throwaway keychain file; the SDK tests cover `PluginStorage` against one.
final class FakeKeychain: HistoryKeychain {
    struct Item: Equatable {
        var data: Data
        var access: KeychainAccess?
    }

    /// How a save under an account in `failingSets` fails.
    enum SetFailure {
        /// It throws and stores nothing, like a locked keychain.
        case refused
        /// It stores the item and then throws, like a process that exits right after the save.
        case afterStoring
    }

    private struct State {
        var items: [String: Item] = [:]
        var needsAccess: Set<String> = []
        var failingSets: [String: SetFailure] = [:]
        var calls: [(name: String, onMain: Bool)] = []
        var isHeld = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var items: [String: Item] {
        get { state.withLock { $0.items } }
        set { state.withLock { $0.items = newValue } }
    }

    var needsAccess: Set<String> {
        get { state.withLock { $0.needsAccess } }
        set { state.withLock { $0.needsAccess = newValue } }
    }

    var failingSets: [String: SetFailure] {
        get { state.withLock { $0.failingSets } }
        set { state.withLock { $0.failingSets = newValue } }
    }

    var isHeld: Bool {
        get { state.withLock { $0.isHeld } }
        set { state.withLock { $0.isHeld = newValue } }
    }

    var calls: [(name: String, onMain: Bool)] { state.withLock { $0.calls } }

    func keychainData(for account: String) throws(KeychainError) -> Data? {
        try call("read \(account)", account) { $0.items[account]?.data }
    }

    func setKeychainData(_ data: Data, for account: String, access: KeychainAccess) throws(KeychainError) {
        let failure = failingSets[account]
        try call("set \(account)", account) { state in
            if failure != .refused { state.items[account] = Item(data: data, access: access) }
        }
        if failure != nil { throw KeychainError(status: errSecInteractionNotAllowed) }
    }

    func deleteKeychainData(for account: String) throws(KeychainError) {
        try call("delete \(account)", account) { $0.items[account] = nil }
    }

    private func call<T>(_ name: String, _ account: String, _ body: (inout State) -> T) throws(KeychainError) -> T {
        let onMain = Thread.isMainThread
        while state.withLock({ $0.isHeld }) {
            Thread.sleep(forTimeInterval: 0.001)
        }
        let result: Result<T, KeychainError> = state.withLockUnchecked { state in
            state.calls.append((name, onMain))
            guard !state.needsAccess.contains(account) else { return .failure(KeychainError(status: errSecAuthFailed)) }
            return .success(body(&state))
        }
        return try result.get()
    }
}

private func bytes(of key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

/// A history in `directory` written with `key`, one text entry.
@MainActor
private func writeHistory(in directory: URL, key: SymmetricKey, text: String) {
    let history = makeHistory(directory: directory, key: key)
    history.record(.text(text))
    history.flush()
}

@Test func R09__the_first_key_is_created_for_any_application() throws {
    let keychain = FakeKeychain()
    let first = try ClipboardStore.open(in: try makeDirectory(), keychain: keychain)
    #expect(first.origin == .created)
    let item = try #require(keychain.items[HistoryKey.account])
    #expect(item == FakeKeychain.Item(data: bytes(of: first.key), access: .anyApplication))
    #expect(keychain.items[HistoryKey.legacyAccount] == nil)

    let again = try ClipboardStore.open(in: try makeDirectory(), keychain: keychain)
    #expect(again.origin == .stored)
    #expect(bytes(of: again.key) == bytes(of: first.key))
}

/// A key from before SDK 1.2 that this build can still read moves to the new account for any
/// application, so later builds never ask; the history stays readable.
@MainActor
@Test func R09__a_readable_old_key_moves_to_the_new_account_for_any_application() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    writeHistory(in: directory, key: key, text: "kept across the move")
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: key), access: nil)

    let opened = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(opened.origin == .movedFromOldAccount)
    #expect(bytes(of: opened.key) == bytes(of: key))
    #expect(keychain.items[HistoryKey.account] == FakeKeychain.Item(data: bytes(of: key), access: .anyApplication))
    #expect(keychain.items[HistoryKey.legacyAccount] == nil)
    #expect(makeHistory(directory: directory, key: opened.key).items.map(\.content) == [.text("kept across the move")])
}

/// A key from before SDK 1.2 that cannot be read without asking: a new key goes under the new
/// account, the old history's files are removed, and the old item is deleted only when that needs
/// no dialog (here it fails, and the failure is ignored). It happens once.
@MainActor
@Test func R09__an_old_key_that_needs_access_starts_a_new_history_once() throws {
    let directory = try makeDirectory()
    writeHistory(in: directory, key: makeKey(), text: "sealed with the old key")
    #expect(try !files(in: directory).isEmpty)
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: makeKey()), access: nil)
    keychain.needsAccess = [HistoryKey.legacyAccount]

    let opened = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(opened.origin == .replacedOldKeyThatNeedsAccess)
    #expect(try files(in: directory).isEmpty)
    #expect(keychain.items[HistoryKey.account] == FakeKeychain.Item(data: bytes(of: opened.key), access: .anyApplication))
    #expect(keychain.calls.map(\.name).contains("delete \(HistoryKey.legacyAccount)"))

    writeHistory(in: directory, key: opened.key, text: "the new history")
    let reopened = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(reopened.origin == .stored)
    #expect(makeHistory(directory: directory, key: reopened.key).items.map(\.content) == [.text("the new history")])
}

/// A key under the new account that cannot be read now (a locked keychain) is never replaced, and
/// the history on disk stays as it is.
@MainActor
@Test func R09__a_current_key_that_needs_access_is_never_replaced() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    writeHistory(in: directory, key: key, text: "still here")
    let stored = try contents(of: directory)
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.account] = FakeKeychain.Item(data: bytes(of: key), access: .anyApplication)
    keychain.needsAccess = [HistoryKey.account]

    #expect(throws: KeychainError(status: errSecAuthFailed)) { try ClipboardStore.open(in: directory, keychain: keychain) }
    #expect(try contents(of: directory) == stored)
    #expect(keychain.calls.map(\.name) == ["read \(HistoryKey.account)"])
}

/// What is stored under the key's account but is not a 256-bit key is left in place.
@Test func R09__a_stored_key_of_the_wrong_size_is_left_in_place() throws {
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.account] = FakeKeychain.Item(data: Data([1, 2, 3]), access: .anyApplication)
    #expect(throws: HistoryKey.InvalidKeyError.self) { try ClipboardStore.open(in: try makeDirectory(), keychain: keychain) }
    #expect(keychain.items[HistoryKey.account]?.data == Data([1, 2, 3]))
}

/// The keychain of a history sealed with an old key that cannot be read without asking.
@MainActor
private func keychainWithOldKeyThatNeedsAccess(over directory: URL) -> FakeKeychain {
    writeHistory(in: directory, key: makeKey(), text: "sealed with the old key")
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: makeKey()), access: nil)
    keychain.needsAccess = [HistoryKey.legacyAccount]
    return keychain
}

/// After an interrupted move to a new key: the next open deletes the old history and returns a
/// store that keeps new copies, and nothing it leaves behind deletes them on a later open.
@MainActor
private func expectOpenFinishesTheNewHistory(in directory: URL, keychain: FakeKeychain) throws {
    let opened = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(opened.origin == .stored)
    #expect(try files(in: directory).isEmpty)

    let history = ClipboardHistory(logError: { _ in })
    history.open(opened.store)
    #expect(!history.isStoreUnreadable)
    history.record(.text("copied after the new key"))
    history.flush()

    let reopened = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(makeHistory(directory: directory, key: reopened.key).items.map(\.content) == [.text("copied after the new key")])
}

/// The process stops right after the new key is saved, before the old history is deleted: the
/// next open deletes it and new copies are saved again.
@MainActor
@Test func R09__a_new_key_saved_before_an_interruption_finishes_the_new_history_next_time() throws {
    let directory = try makeDirectory()
    let keychain = keychainWithOldKeyThatNeedsAccess(over: directory)
    keychain.failingSets = [HistoryKey.account: .afterStoring]

    #expect(throws: KeychainError.self) { try ClipboardStore.open(in: directory, keychain: keychain) }
    #expect(keychain.items[HistoryKey.account] != nil)
    keychain.failingSets = [:]

    try expectOpenFinishesTheNewHistory(in: directory, keychain: keychain)
}

/// Deleting the old history fails after the new key is saved: the next open deletes it once the
/// disk allows it, and new copies are saved again.
@MainActor
@Test func R09__an_old_history_that_could_not_be_deleted_is_deleted_next_time() throws {
    let directory = try makeDirectory()
    let keychain = keychainWithOldKeyThatNeedsAccess(over: directory)
    let list = directory.appendingPathComponent(ClipboardStore.listFileName).path
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: list)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: list) }

    #expect(throws: (any Error).self) { try ClipboardStore.open(in: directory, keychain: keychain) }
    #expect(keychain.items[HistoryKey.account] != nil)
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: list)

    try expectOpenFinishesTheNewHistory(in: directory, keychain: keychain)
}

/// A new key that could not be saved leaves the history in place when the old key can be read
/// next time: that key moves and its history stays, now and on later opens.
@MainActor
@Test func R09__a_history_whose_old_key_becomes_readable_is_kept() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    writeHistory(in: directory, key: key, text: "kept")
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: key), access: nil)
    keychain.needsAccess = [HistoryKey.legacyAccount]
    keychain.failingSets = [HistoryKey.account: .refused]

    #expect(throws: KeychainError.self) { try ClipboardStore.open(in: directory, keychain: keychain) }
    #expect(keychain.items[HistoryKey.account] == nil)
    keychain.needsAccess = []
    keychain.failingSets = [:]

    let moved = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(moved.origin == .movedFromOldAccount)
    #expect(makeHistory(directory: directory, key: moved.key).items.map(\.content) == [.text("kept")])
    let again = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(makeHistory(directory: directory, key: again.key).items.map(\.content) == [.text("kept")])
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

/// The plugin with its files in `directory`, a fake keychain and a private pasteboard.
@MainActor
private func makePlugin(directory: URL, keychain: FakeKeychain, pasteboard: NSPasteboard, host: LogHost = LogHost()) throws -> ClipboardPlugin {
    let id = ClipboardPlugin.manifest.id
    let storage = try PluginStorage(directory: directory, defaultsSuiteName: "clipboard-tests.\(id)", keychainService: "clipboard-tests.\(id)")
    return ClipboardPlugin(
        context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage),
        keychain: keychain,
        pasteboard: pasteboard
    )
}

/// `activate()` returns at once and the history stays empty while the keychain call waits; every
/// keychain call runs off the main thread. A new history that replaces an unreadable one is logged
/// at info level, and copies are recorded once the history is open.
@MainActor
@Test func R09__the_plugin_never_calls_the_keychain_on_the_main_thread() async throws {
    let directory = try makeDirectory()
    writeHistory(in: directory, key: makeKey(), text: "sealed with the old key")
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: makeKey()), access: nil)
    keychain.needsAccess = [HistoryKey.legacyAccount]
    keychain.isHeld = true
    let host = LogHost()
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = try makePlugin(directory: directory, keychain: keychain, pasteboard: pasteboard, host: host)

    plugin.activate()
    #expect(plugin.history.items.isEmpty)
    keychain.isHeld = false
    await plugin.opening?.value

    #expect(!keychain.calls.isEmpty)
    #expect(keychain.calls.allSatisfy { !$0.onMain }, "\(keychain.calls)")
    #expect(host.logs.contains { $0.0 == .info && $0.1.contains("new clipboard history") }, "\(host.logs)")
    #expect(try files(in: directory).isEmpty)

    pasteboard.clearContents()
    pasteboard.setString("copied after opening", forType: .string)
    try await Task.sleep(for: PasteboardMonitor.interval * 3)
    plugin.deactivate()
    #expect(plugin.history.items.map(\.content) == [.text("copied after opening")])
    let key = SymmetricKey(data: try #require(keychain.items[HistoryKey.account]).data)
    #expect(makeHistory(directory: directory, key: key).items.map(\.content) == [.text("copied after opening")])
}

/// Copies made while the key loads are kept and recorded once the history opens, oldest first, by
/// the same rules as any copy: a repeat moves the stored entry to the top. Then they are saved.
@MainActor
@Test func R09__copies_made_while_the_key_loads_are_recorded_once_the_history_opens() async throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let stored = makeHistory(directory: directory, key: key)
    stored.record(.text("from the last session"))
    stored.record(.text("copied again"))
    stored.flush()
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.account] = FakeKeychain.Item(data: bytes(of: key), access: .anyApplication)
    keychain.isHeld = true
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = try makePlugin(directory: directory, keychain: keychain, pasteboard: pasteboard)

    plugin.activate()
    for text in ["copied again", "copied while the key loads"] {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try await Task.sleep(for: PasteboardMonitor.interval * 3)
    }
    keychain.isHeld = false
    await plugin.opening?.value
    plugin.deactivate()

    let expected: [ClipItem.Content] = [.text("copied while the key loads"), .text("copied again"), .text("from the last session")]
    #expect(plugin.history.items.map(\.content) == expected)
    #expect(makeHistory(directory: directory, key: key).items.map(\.content) == expected)
}

/// What the pasteboard holds when the plugin starts is recorded like a new copy.
@MainActor
@Test func R09__the_item_on_the_pasteboard_at_activation_is_recorded() async throws {
    let directory = try makeDirectory()
    let keychain = FakeKeychain()
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    pasteboard.setString("copied before the plugin started", forType: .string)
    let plugin = try makePlugin(directory: directory, keychain: keychain, pasteboard: pasteboard)

    plugin.activate()
    await plugin.opening?.value
    plugin.deactivate()

    #expect(plugin.history.items.map(\.content) == [.text("copied before the plugin started")])
    let key = SymmetricKey(data: try #require(keychain.items[HistoryKey.account]).data)
    #expect(makeHistory(directory: directory, key: key).items.map(\.content) == [.text("copied before the plugin started")])
}

/// Puts `text` on `pasteboard` as a new copy.
private func put(_ text: String, on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
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

/// The list on disk, opened with the key now under the key's account.
private func storedContents(in directory: URL, keychain: FakeKeychain) throws -> [ClipItem.Content] {
    let key = SymmetricKey(data: try #require(keychain.items[HistoryKey.account]).data)
    return try ClipboardStore(directory: directory, key: key).loadList().map(\.content)
}

extension MainActorTimingTests {
    /// However long the key takes to load, a copy shows in the list within a second, and it is saved
    /// once the history opens.
    @MainActor
    @Test func R09__a_copy_shows_within_a_second_while_the_key_loads() async throws {
        let directory = try makeDirectory()
        let keychain = FakeKeychain()
        keychain.isHeld = true
        defer { keychain.isHeld = false }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let plugin = try makePlugin(directory: directory, keychain: keychain, pasteboard: pasteboard)

        await waitForAQuietMainActor()
        plugin.activate()
        put("copied while the key loads", on: pasteboard)
        #expect(await showsWithinASecond(.text("copied while the key loads"), in: plugin.history))
        #expect(keychain.calls.isEmpty, "the key is still loading")

        keychain.isHeld = false
        await plugin.opening?.value
        plugin.deactivate()
        #expect(plugin.history.items.map(\.content) == [.text("copied while the key loads")])
        #expect(try storedContents(in: directory, keychain: keychain) == [.text("copied while the key loads")])
    }
}

extension MainActorTimingTests {
    /// Turning the feature off while the key loads loses no copy made meanwhile: turned on again, the
    /// history opens with every one of them, newest first, and saves them.
    @MainActor
    @Test func R09__copies_survive_turning_off_while_the_key_loads() async throws {
        let directory = try makeDirectory()
        let keychain = FakeKeychain()
        keychain.isHeld = true
        defer { keychain.isHeld = false }
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let plugin = try makePlugin(directory: directory, keychain: keychain, pasteboard: pasteboard)

        await waitForAQuietMainActor()
        plugin.activate()
        for text in ["copy A", "copy B"] {
            put(text, on: pasteboard)
            #expect(await showsWithinASecond(.text(text), in: plugin.history))
        }
        plugin.deactivate()
        keychain.isHeld = false
        plugin.activate()
        await plugin.opening?.value
        plugin.deactivate()

        let expected: [ClipItem.Content] = [.text("copy B"), .text("copy A")]
        #expect(plugin.history.items.map(\.content) == expected)
        #expect(try storedContents(in: directory, keychain: keychain) == expected)
    }
}

/// A new key that could not be stored leaves the marker; later the old key can be read and is
/// saved under the new account, and the process stops before the marker goes. The next open finds
/// a list that opens with its key: it keeps that history and only drops the marker.
@MainActor
@Test func R09__a_stale_marker_never_deletes_a_history_the_key_opens() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    writeHistory(in: directory, key: key, text: "readable with the key")
    let marker = directory.appendingPathComponent(ClipboardStore.oldHistoryMarkerName)
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: key), access: nil)
    keychain.needsAccess = [HistoryKey.legacyAccount]
    keychain.failingSets = [HistoryKey.account: .refused]
    #expect(throws: KeychainError.self) { try ClipboardStore.open(in: directory, keychain: keychain) }
    #expect(FileManager.default.fileExists(atPath: marker.path))

    keychain.needsAccess = []
    keychain.failingSets = [HistoryKey.account: .afterStoring]
    #expect(throws: KeychainError.self) { try ClipboardStore.open(in: directory, keychain: keychain) }
    #expect(keychain.items[HistoryKey.account]?.data == bytes(of: key))
    #expect(FileManager.default.fileExists(atPath: marker.path))
    keychain.failingSets = [:]

    let opened = try ClipboardStore.open(in: directory, keychain: keychain)
    #expect(opened.origin == .stored)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    #expect(makeHistory(directory: directory, key: opened.key).items.map(\.content) == [.text("readable with the key")])
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

/// What is on disk and in the keychain when a random session starts.
private enum SessionStart: CaseIterable {
    case firstRun, readableOldKey, oldKeyThatNeedsAccess, staleMarkerOnReadableHistory
}

/// How the keychain answers: waiting, as it should, refusing the key's account, or storing a key
/// and then failing like a process that stops right after.
private enum KeyState {
    case held, healthy, failing, interruptedAfterSave
}

private enum SessionStep {
    case copy, activate, deactivate, holdKey, releaseKey, failKey, interruptAfterKeySave, reopen
}

private func apply(_ state: KeyState, to keychain: FakeKeychain, needingAccess base: Set<String>) {
    keychain.needsAccess = state == .failing ? base.union([HistoryKey.account]) : base
    keychain.failingSets = state == .interruptedAfterSave ? [HistoryKey.account: .afterStoring] : [:]
    keychain.isHeld = state == .held
}

extension MainActorTimingTests {
    /// Random sessions from fixed seeds: copies, turning the feature off and on, and a key that waits,
    /// fails or is saved right before an interruption. After each copy it must show within a second;
    /// once the keychain answers again and the history opens: every copy is listed and saved, newest
    /// first; a history that the final key opens was never deleted; no marker is left; and no keychain
    /// call ran on the main thread.
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
    let keychain = FakeKeychain()
    defer { keychain.isHeld = false }
    var initialKey: SymmetricKey?
    if start != .firstRun {
        let key = makeKey()
        writeHistory(in: directory, key: key, text: "from before")
        initialKey = key
        switch start {
        case .readableOldKey:
            keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: key), access: nil)
        case .oldKeyThatNeedsAccess:
            keychain.items[HistoryKey.legacyAccount] = FakeKeychain.Item(data: bytes(of: key), access: nil)
            keychain.needsAccess = [HistoryKey.legacyAccount]
        case .staleMarkerOnReadableHistory:
            keychain.items[HistoryKey.account] = FakeKeychain.Item(data: bytes(of: key), access: .anyApplication)
            try Data().write(to: marker)
        case .firstRun:
            break
        }
    }
    let needingAccess = keychain.needsAccess
    // Even seeds start with a key save that is interrupted, so a first key or a moved one is saved
    // and the open still fails; odd seeds start with a key that waits.
    var keyState: KeyState = seed.isMultiple(of: 2) ? .interruptedAfterSave : .held
    apply(keyState, to: keychain, needingAccess: needingAccess)
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = try makePlugin(directory: directory, keychain: keychain, pasteboard: pasteboard)

    await waitForAQuietMainActor()
    var log = ["seed \(seed)", "\(start)", "\(keyState)"]
    var copies: [String] = []
    var isActive = false
    let steps: [SessionStep] = [.copy, .copy, .copy, .activate, .deactivate, .holdKey, .releaseKey, .failKey, .interruptAfterKeySave, .reopen]
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
        case .holdKey, .releaseKey, .failKey, .interruptAfterKeySave:
            let states: [SessionStep: KeyState] = [.holdKey: .held, .releaseKey: .healthy, .failKey: .failing, .interruptAfterKeySave: .interruptedAfterSave]
            keyState = states[step]!
            apply(keyState, to: keychain, needingAccess: needingAccess)
        case .reopen:
            if isActive { plugin.deactivate() }
            plugin.activate()
            isActive = true
        }
        if isActive && keyState != .held {
            await plugin.opening?.value
        }
    }

    // The keychain answers again and the feature is turned off and on, so an opening finishes.
    apply(.healthy, to: keychain, needingAccess: needingAccess)
    if isActive { plugin.deactivate() }
    plugin.activate()
    await plugin.opening?.value
    plugin.deactivate()

    let comment = Comment(rawValue: log.joined(separator: ", "))
    let copied = copies.reversed().map { ClipItem.Content.text($0) }
    #expect(plugin.history.items.map(\.content).filter { copied.contains($0) } == copied, comment)
    #expect(plugin.history.unsavedCount == 0, comment)
    let finalKey = SymmetricKey(data: try #require(keychain.items[HistoryKey.account], comment).data)
    let stored = try #require(try? ClipboardStore(directory: directory, key: finalKey).loadList(), comment)
    #expect(stored.map(\.content) == plugin.history.items.map(\.content), comment)
    #expect(!FileManager.default.fileExists(atPath: marker.path), comment)
    if let initialKey {
        let historyOpensWithFinalKey = bytes(of: initialKey) == bytes(of: finalKey)
        #expect(stored.map(\.content).contains(.text("from before")) == historyOpensWithFinalKey, comment)
        if start != .oldKeyThatNeedsAccess {
            #expect(historyOpensWithFinalKey, comment)
        }
    }
    #expect(keychain.calls.allSatisfy { !$0.onMain }, comment)
}

/// The plugin over a stored history of `stored`, newest first, with `pinned` among them pinned,
/// activated while its key loads: copies show, but the stored history is not read yet.
@MainActor
private func activateWhileTheKeyLoads(over stored: [String], pinned: Set<String> = [], pasteboard: NSPasteboard) throws -> (plugin: ClipboardPlugin, keychain: FakeKeychain, directory: URL) {
    let directory = try makeDirectory()
    let key = makeKey()
    let history = makeHistory(directory: directory, key: key)
    for text in stored.reversed() {
        history.record(.text(text))
    }
    for item in history.items where pinned.contains(item.text ?? "") {
        history.setPinned(true, for: item.id)
    }
    history.flush()
    let keychain = FakeKeychain()
    keychain.items[HistoryKey.account] = FakeKeychain.Item(data: bytes(of: key), access: .anyApplication)
    keychain.isHeld = true
    let plugin = try makePlugin(directory: directory, keychain: keychain, pasteboard: pasteboard)
    plugin.activate()
    return (plugin, keychain, directory)
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

/// Lets the key load, waits until the history opens and turns the feature off.
@MainActor
private func finishOpening(_ plugin: ClipboardPlugin, keychain: FakeKeychain) async {
    keychain.isHeld = false
    await plugin.opening?.value
    plugin.deactivate()
}

/// The entry holding `text`, in the list in memory.
@MainActor
private func entry(_ text: String, in plugin: ClipboardPlugin) throws -> ClipItem {
    try #require(plugin.history.items.first { $0.content == .text(text) })
}

/// A copy deleted while the key loads stays deleted once the stored history, which holds the same
/// text, opens.
@MainActor
@Test func R09__a_copy_deleted_while_the_history_opens_stays_deleted() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let (plugin, keychain, directory) = try activateWhileTheKeyLoads(over: ["deleted", "kept"], pasteboard: pasteboard)
    defer { keychain.isHeld = false }

    try await copy("deleted", on: pasteboard, into: plugin)
    plugin.history.delete(try entry("deleted", in: plugin).id)
    await finishOpening(plugin, keychain: keychain)

    #expect(plugin.history.items.map(\.content) == [.text("kept")])
    #expect(try storedContents(in: directory, keychain: keychain) == [.text("kept")])
}

/// Clearing while the key loads clears the unpinned entries of the stored history too; a pinned
/// one stays, and so does a copy made after the clearing.
@MainActor
@Test func R09__clearing_while_the_history_opens_clears_the_stored_entries_too() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let (plugin, keychain, directory) = try activateWhileTheKeyLoads(over: ["stored 1", "pinned", "stored 2"], pinned: ["pinned"], pasteboard: pasteboard)
    defer { keychain.isHeld = false }

    try await copy("copied before clearing", on: pasteboard, into: plugin)
    plugin.history.clearUnpinned()
    try await copy("copied after clearing", on: pasteboard, into: plugin)
    await finishOpening(plugin, keychain: keychain)

    let expected: [ClipItem.Content] = [.text("copied after clearing"), .text("pinned")]
    #expect(plugin.history.items.map(\.content) == expected)
    #expect(try storedContents(in: directory, keychain: keychain) == expected)
}

/// A pin set or cleared on a copy while the key loads holds once the stored history opens, whatever
/// the stored entry with the same text had; a copy left alone keeps the stored pin.
@MainActor
@Test func R09__pins_set_or_cleared_while_the_history_opens_hold() async throws {
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let texts = ["pinned now", "unpinned now", "left alone"]
    let (plugin, keychain, directory) = try activateWhileTheKeyLoads(over: texts, pinned: ["unpinned now", "left alone"], pasteboard: pasteboard)
    defer { keychain.isHeld = false }

    for text in texts.reversed() {
        try await copy(text, on: pasteboard, into: plugin)
    }
    plugin.history.setPinned(true, for: try entry("pinned now", in: plugin).id)
    plugin.history.setPinned(true, for: try entry("unpinned now", in: plugin).id)
    plugin.history.setPinned(false, for: try entry("unpinned now", in: plugin).id)
    await finishOpening(plugin, keychain: keychain)

    let expected = ["pinned now": true, "unpinned now": false, "left alone": true]
    let pins = Dictionary(uniqueKeysWithValues: plugin.history.items.map { ($0.text ?? "", $0.isPinned) })
    #expect(pins == expected)
    let key = SymmetricKey(data: try #require(keychain.items[HistoryKey.account]).data)
    let stored = try ClipboardStore(directory: directory, key: key).loadList()
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
