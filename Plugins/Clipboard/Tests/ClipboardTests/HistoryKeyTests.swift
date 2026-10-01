import AppKit
import CryptoKit
import Foundation
import NotchKit
import os
import Security
import Testing
@testable import Clipboard

/// A keychain in memory that records, for every call, whether it ran on the main thread. Accounts in
/// `needsAccess` fail like an item macOS would ask the user about. While `isHeld` is on, every call
/// waits, like a keychain call waiting on the security daemon.
///
/// `NotchKit` keeps its temporary-keychain switch internal, so this package cannot point a
/// `PluginStorage` at a throwaway keychain file; the SDK tests cover `PluginStorage` against one.
final class FakeKeychain: HistoryKeychain {
    struct Item: Equatable {
        var data: Data
        var access: KeychainAccess?
    }

    private struct State {
        var items: [String: Item] = [:]
        var needsAccess: Set<String> = []
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

    var isHeld: Bool {
        get { state.withLock { $0.isHeld } }
        set { state.withLock { $0.isHeld = newValue } }
    }

    var calls: [(name: String, onMain: Bool)] { state.withLock { $0.calls } }

    func keychainData(for account: String) throws(KeychainError) -> Data? {
        try call("read \(account)", account) { $0.items[account]?.data }
    }

    func setKeychainData(_ data: Data, for account: String, access: KeychainAccess) throws(KeychainError) {
        try call("set \(account)", account) { $0.items[account] = Item(data: data, access: access) }
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
    let id = ClipboardPlugin.manifest.id
    let storage = try PluginStorage(directory: directory, defaultsSuiteName: "clipboard-tests.\(id)", keychainService: "clipboard-tests.\(id)")
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = ClipboardPlugin(
        context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: host, storage: storage),
        keychain: keychain,
        pasteboard: pasteboard
    )

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
