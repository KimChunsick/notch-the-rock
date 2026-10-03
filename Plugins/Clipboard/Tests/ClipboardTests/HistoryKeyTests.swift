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

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Runs ClipboardTestHelper as another process: it opens the history in `directory` the way the
/// plugin does, records `texts`, saves and prints the key it opened the history with, in hex.
private func runHelper(in directory: URL, recording texts: [String]) throws -> (status: Int32, printed: String) {
    let helper = Process()
    helper.executableURL = Bundle(for: OpeningGate.self).bundleURL
        .deletingLastPathComponent().appendingPathComponent("ClipboardTestHelper")
    helper.arguments = [directory.path] + texts
    let output = Pipe()
    helper.standardOutput = output
    try helper.run()
    let printed = output.fileHandleForReading.readDataToEndOfFile()
    helper.waitUntilExit()
    return (helper.terminationStatus, String(decoding: printed, as: UTF8.self))
}

/// The list on disk, opened with the key in the key file.
private func storedContents(in directory: URL) throws -> [ClipItem.Content] {
    try ClipboardStore(directory: directory, key: storedKey(in: directory)).loadList().map(\.content)
}

/// The names of the regular files in `directory`.
private func fileNames(in directory: URL) throws -> Set<String> {
    Set(try files(in: directory).map(\.lastPathComponent))
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

/// The plugin with its storage folder at `directory`, opening through `gate`, and a private
/// pasteboard. Each call builds a new `PluginStorage`, as a new process would.
@MainActor
private func makePlugin(directory: URL, gate: OpeningGate = OpeningGate(), pasteboard: NSPasteboard, host: FakeHost = FakeHost()) throws -> ClipboardPlugin {
    ClipboardPlugin(
        context: try makeContext(directory: directory, host: host),
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
    let lock = try entryStatus(directory.appendingPathComponent(ClipboardStore.openingLockName))
    #expect(lock.st_mode & S_IFMT == S_IFREG)
    #expect(lock.st_mode & 0o7777 == 0o600)
    #expect(lock.st_size == 0)

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

/// Another process opens the history the way the plugin does, saves two copies and exits; this
/// process then opens the same folder from the key file, with the same key, and finds the copies.
@MainActor
@Test func R57__another_process_reopens_the_history_with_the_same_key() throws {
    let directory = try makeDirectory()
    let helper = try runHelper(in: directory, recording: ["copied in the other process", "copied there last"])
    #expect(helper.status == 0)

    let opened = try ClipboardStore.open(in: directory)
    let keyBytes = bytes(of: opened.key)
    #expect(opened.origin == .stored)
    #expect(hex(keyBytes) + "\n" == helper.printed)
    #expect(try Data(contentsOf: keyFile(in: directory)) == keyBytes)
    let history = ClipboardHistory(logError: { _ in })
    history.open(opened.store)
    #expect(history.items.map(\.content) == [.text("copied there last"), .text("copied in the other process")])
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
    #expect(try fileNames(in: directory) == [HistoryKey.fileName, ClipboardStore.openingLockName])
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
    #expect(Set(stored.keys) == [HistoryKey.fileName, ClipboardStore.listFileName, ClipboardStore.openingLockName])
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
    #expect(try fileNames(in: directory) == [HistoryKey.fileName, ClipboardStore.openingLockName])

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
    #expect(try fileNames(in: directory) == [HistoryKey.fileName, ClipboardStore.openingLockName])
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

// MARK: - Openings at the same time

/// Runs `body` on a thread of its own, so that it can wait without holding a thread of the test's.
private func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: body()) }
    }
}

/// Opens `directory` twice at once, as two processes starting together would. The first opening
/// stops at `step` until the second has either finished or started waiting for the first; the
/// second saves `text` as soon as it is open. Every wait gives up after a minute, so an opening
/// that is stuck fails the test instead of hanging it.
private func openTwice(
    _ directory: URL, firstStopsAt step: ClipboardStore.OpeningStep, secondSaves text: String
) async throws -> (first: ClipboardStore.Opened, second: ClipboardStore.Opened) {
    let firstStopped = DispatchSemaphore(value: 0)
    let resumeFirst = DispatchSemaphore(value: 0)
    let secondWaitsOrIsDone = DispatchSemaphore(value: 0)
    async let first = onThread {
        Result {
            try ClipboardStore.open(in: directory) {
                guard $0 == step else { return }
                firstStopped.signal()
                _ = resumeFirst.wait(timeout: .now() + 60)
            }
        }
    }
    #expect(await onThread { firstStopped.wait(timeout: .now() + 60) } == .success, "the first opening never got to \(step)")
    async let second = onThread {
        defer { secondWaitsOrIsDone.signal() }
        return Result {
            let opened = try ClipboardStore.open(in: directory) {
                if $0 == .waitingForLock { secondWaitsOrIsDone.signal() }
            }
            try opened.store.saveList([ClipItem(id: UUID(), content: .text(text), date: .now, isPinned: false)])
            return opened
        }
    }
    #expect(await onThread { secondWaitsOrIsDone.wait(timeout: .now() + 60) } == .success)
    resumeFirst.signal()
    return try (await first.get(), await second.get())
}

/// Two openings find a key file that is not trusted. The second cannot finish while the first is
/// between finding it and replacing it, so the first never removes a key file the second created:
/// both get the one key in the key file, and what the second saved with it stays readable.
@MainActor
@Test func R57__two_openings_replacing_an_untrusted_key_file_end_with_one_key() async throws {
    let directory = try makeDirectory()
    writeHistory(in: directory, key: try ClipboardStore.open(in: directory).key, text: "sealed with the distrusted key")
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile(in: directory).path)

    let (first, second) = try await openTwice(directory, firstStopsAt: .keyInspected, secondSaves: "saved by the second opening")

    let stored = bytes(of: try storedKey(in: directory))
    #expect(bytes(of: first.key) == stored)
    #expect(bytes(of: second.key) == stored)
    #expect(try storedContents(in: directory) == [.text("saved by the second opening")])
}

/// Two openings find a history from before the key file. The second cannot finish while the first
/// is between finding that the list does not open and deleting it, so the first never deletes the
/// history the second saved with the new key.
@MainActor
@Test func R57__an_opening_never_deletes_a_history_another_opening_saved() async throws {
    let directory = try makeDirectory()
    try writeHistoryFromBeforeTheKeyFile(in: directory)

    let (first, second) = try await openTwice(directory, firstStopsAt: .oldHistoryChecked, secondSaves: "saved by the second opening")

    #expect(bytes(of: first.key) == bytes(of: second.key))
    #expect(first.removedOldHistory && !second.removedOldHistory)
    #expect(try storedContents(in: directory) == [.text("saved by the second opening")])
    #expect(try fileNames(in: directory) == [HistoryKey.fileName, ClipboardStore.listFileName, ClipboardStore.openingLockName])
}

/// While another opening holds the lock longer than an opening waits, that opening fails and
/// changes nothing: no key file is created and the old history, marker included, stays.
@MainActor
@Test func R57__an_opening_that_cannot_take_the_lock_changes_nothing() throws {
    let directory = try makeDirectory()
    try writeHistoryFromBeforeTheKeyFile(in: directory, withMarker: true)
    let holder = open(directory.appendingPathComponent(ClipboardStore.openingLockName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    try #require(holder >= 0)
    defer { close(holder) }
    try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)
    let before = try contents(of: directory)

    let error = #expect(throws: POSIXError.self) {
        try ClipboardStore.open(in: directory, waitingAtMost: .milliseconds(200))
    }

    #expect(error?.code == .ETIMEDOUT)
    #expect(try contents(of: directory) == before)
}

// MARK: - Resetting a history that could not be read

/// This session could not read the history when it opened it. Then another opening read the same
/// folder, after access came back or with a key file it replaced, and saved a copy there. The
/// reset this session asks for next finds a history it can read with the key in the key file, so
/// it deletes nothing: it keeps that history, adds this session's copy and saves both with that key.
@MainActor
@Test(arguments: ["access came back", "the key file was replaced"])
func R57__a_reset_never_deletes_a_history_another_opening_saved(_ change: String) async throws {
    let directory = try makeDirectory()
    let list = directory.appendingPathComponent(ClipboardStore.listFileName)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: list.path) }
    let opened = try ClipboardStore.open(in: directory)
    let history = ClipboardHistory(logError: { _ in })
    var expected: [ClipItem.Content] = [.text("copied in this session"), .text("saved by the other opening")]
    func otherOpeningSaves() throws {
        let other = ClipboardHistory(logError: { _ in })
        other.open(try ClipboardStore.open(in: directory).store)
        other.record(.text("saved by the other opening"))
        other.flush()
    }
    if change == "access came back" {
        writeHistory(in: directory, key: opened.key, text: "saved before the read failed")
        expected.append(.text("saved before the read failed"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: list.path)
        history.open(opened.store)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: list.path)
        try otherOpeningSaves()
    } else {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile(in: directory).path)
        try otherOpeningSaves()
        history.open(opened.store)
    }
    #expect(history.isStoreUnreadable)
    let keyBytes = try Data(contentsOf: keyFile(in: directory))
    history.record(.text("copied in this session"))

    await history.resetUnreadableStore()
    history.flush()

    #expect(!history.isStoreUnreadable)
    #expect(history.items.map(\.content) == expected)
    #expect(try Data(contentsOf: keyFile(in: directory)) == keyBytes)
    #expect(try storedContents(in: directory) == expected)
}

/// A reset holds the opening lock from finding the list unreadable to deleting it: an opening that
/// starts in between waits until the reset is done, so what that opening saves stays.
@MainActor
@Test func R57__an_opening_waits_until_a_reset_has_deleted() throws {
    let directory = try makeDirectory()
    let store = try ClipboardStore.open(in: directory).store
    writeHistory(in: directory, key: makeKey(), text: "sealed with another key")
    let openingWaits = DispatchSemaphore(value: 0)
    let openingSaved = DispatchSemaphore(value: 0)
    let failure = OSAllocatedUnfairLock<String?>(initialState: nil)

    let reset = try store.resetIfUnreadable { step in
        guard step == .unreadableHistoryChecked else { return }
        Thread.detachNewThread {
            defer { openingSaved.signal() }
            do {
                let opened = try ClipboardStore.open(in: directory) {
                    if $0 == .waitingForLock { openingWaits.signal() }
                }
                try opened.store.saveList([ClipItem(id: UUID(), content: .text("saved by the opening"), date: .now, isPinned: false)])
            } catch {
                failure.withLock { $0 = "\(error)" }
            }
        }
        #expect(openingWaits.wait(timeout: .now() + 60) == .success, "the opening did not wait for the reset")
    }

    #expect(openingSaved.wait(timeout: .now() + 60) == .success)
    #expect(failure.withLock { $0 } == nil)
    guard case .deleted = reset else {
        Issue.record("the reset found the list sealed with another key readable")
        return
    }
    #expect(try storedContents(in: directory) == [.text("saved by the opening")])
}

/// While another opening holds the lock longer than a reset waits, the reset fails and deletes
/// nothing.
@MainActor
@Test func R57__a_reset_that_cannot_take_the_lock_deletes_nothing() throws {
    let directory = try makeDirectory()
    let store = try ClipboardStore.open(in: directory).store
    writeHistory(in: directory, key: makeKey(), text: "sealed with another key")
    let holder = open(directory.appendingPathComponent(ClipboardStore.openingLockName).path, O_RDWR | O_CLOEXEC)
    try #require(holder >= 0)
    defer { close(holder) }
    try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)
    let before = try contents(of: directory)

    let error = #expect(throws: POSIXError.self) {
        try store.resetIfUnreadable(waitingAtMost: .milliseconds(200))
    }

    #expect(error?.code == .ETIMEDOUT)
    #expect(try contents(of: directory) == before)
}

/// This session could not read the history, and then the key file went: removed, or replaced by a
/// file that is not trusted. A reset gets its key as an opening does, so it saves this session with
/// the key in a new key file and never with a key no trusted file holds: a later opening, in this
/// process or in another, reads what it saved.
@MainActor
@Test(arguments: ["removed", "replaced by an untrusted file"])
func R57__a_reset_saves_only_with_the_key_in_the_key_file(_ change: String) async throws {
    let directory = try makeDirectory()
    let opened = try ClipboardStore.open(in: directory)
    writeHistory(in: directory, key: makeKey(), text: "sealed with another key")
    let history = ClipboardHistory(logError: { _ in })
    history.open(opened.store)
    #expect(history.isStoreUnreadable)
    history.record(.text("copied in this session"))
    try FileManager.default.removeItem(at: keyFile(in: directory))
    if change == "replaced by an untrusted file" {
        try bytes(of: makeKey()).write(to: keyFile(in: directory))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile(in: directory).path)
    }

    await history.resetUnreadableStore()
    history.flush()

    #expect(!history.isStoreUnreadable)
    let reopened = try ClipboardStore.open(in: directory)
    #expect(reopened.origin == .stored)
    #expect(!reopened.removedOldHistory)
    #expect(try reopened.store.loadList().map(\.content) == [.text("copied in this session")])

    let helper = try runHelper(in: directory, recording: ["copied in the other process"])
    #expect(helper.status == 0)
    #expect(helper.printed == hex(try Data(contentsOf: keyFile(in: directory))) + "\n")
    #expect(try storedContents(in: directory) == [.text("copied in the other process"), .text("copied in this session")])
}

extension MainActorTimingTests {
    /// While another opening holds the lock, a reset waits for it on the queue openings use, never
    /// on the main actor: the main actor answers at once, a copy made meanwhile shows at once and a
    /// second reset does nothing. Once the lock is free, the reset opens the history and saves the
    /// copy there.
    @MainActor
    @Test func R09__a_reset_waiting_for_the_lock_leaves_the_main_actor_free() async throws {
        let directory = try makeDirectory()
        let opened = try ClipboardStore.open(in: directory)
        writeHistory(in: directory, key: makeKey(), text: "sealed with another key")
        try Data().write(to: directory.appendingPathComponent(ClipboardStore.oldHistoryMarkerName))
        let history = ClipboardHistory(logError: { _ in })
        history.open(opened.store)
        #expect(history.isStoreUnreadable)
        history.record(.text("copied before the reset"))

        // Another opening stops between finding the old history and deleting it, holding the lock
        // until the test releases it, or five seconds at the latest, counted from a quiet main actor.
        await waitForAQuietMainActor()
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let released = OSAllocatedUnfairLock(initialState: false)
        async let holder = onThread {
            Result {
                try ClipboardStore.open(in: directory) {
                    guard $0 == .oldHistoryChecked else { return }
                    holding.signal()
                    _ = release.wait(timeout: .now() + 5)
                    released.withLock { $0 = true }
                }
            }
        }
        #expect(await onThread { holding.wait(timeout: .now() + 60) } == .success, "the other opening never took the lock")

        let started = ContinuousClock.now
        let resetting = Task { @MainActor in await history.resetUnreadableStore() }
        await Task.yield()
        let answered = await Task { @MainActor in ContinuousClock.now }.value
        #expect(!released.withLock { $0 }, "the main actor answered only once the lock was free")
        #expect(answered - started < .seconds(1), "the main actor answered after \(answered - started)")
        history.record(.text("copied while the reset waits"))
        #expect(history.items.first?.content == .text("copied while the reset waits"))
        await history.resetUnreadableStore()
        #expect(!released.withLock { $0 }, "a second reset waited for the lock")

        release.signal()
        _ = try await holder.get()
        await resetting.value
        history.flush()
        let expected: [ClipItem.Content] = [.text("copied while the reset waits"), .text("copied before the reset")]
        #expect(!history.isStoreUnreadable)
        #expect(history.items.map(\.content) == expected)
        #expect(try storedContents(in: directory) == expected)
    }
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
    let host = FakeHost()
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    let plugin = try makePlugin(directory: directory, gate: gate, pasteboard: pasteboard, host: host)

    plugin.activate()
    #expect(plugin.history.items.isEmpty)
    gate.isHeld = false
    await plugin.opening?.value

    #expect(gate.onMain == [false])
    #expect(host.logs.contains { $0.0 == .info && $0.1.contains("new clipboard history") }, "\(host.logs)")
    #expect(try fileNames(in: directory) == [HistoryKey.fileName, ClipboardStore.openingLockName])

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

/// Whether `history` lists `content` within ten seconds; not a timing check.
@MainActor
private func eventuallyShows(_ content: ClipItem.Content, in history: ClipboardHistory) async throws -> Bool {
    for _ in 0..<500 where !history.items.contains(where: { $0.content == content }) {
        try await Task.sleep(for: .milliseconds(20))
    }
    return history.items.contains { $0.content == content }
}

/// Activating twice starts one opening and one pasteboard monitor. Deactivating saves the history
/// and stops watching, so a later copy is not recorded. Activating again records what the
/// pasteboard holds, watches and saves as the first activation did.
@MainActor
@Test func R64__activating_twice_watches_once_and_activating_again_watches_again() async throws {
    let directory = try makeDirectory()
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    put("copy A", on: pasteboard)
    let plugin = try makePlugin(directory: directory, pasteboard: pasteboard)

    plugin.activate()
    let opening = try #require(plugin.opening)
    plugin.activate()
    #expect(plugin.opening == opening, "a second activation started another opening")
    await opening.value
    put("copy B", on: pasteboard)
    #expect(try await eventuallyShows(.text("copy B"), in: plugin.history))
    plugin.deactivate()
    #expect(plugin.opening == nil)
    #expect(try storedContents(in: directory) == [.text("copy B"), .text("copy A")])

    put("copy C", on: pasteboard)
    try await Task.sleep(for: PasteboardMonitor.interval * 4)
    #expect(!plugin.history.items.contains { $0.content == .text("copy C") }, "a pasteboard monitor kept watching after deactivate")

    plugin.activate()
    #expect(plugin.history.items.first?.content == .text("copy C"))
    await plugin.opening?.value
    put("copy D", on: pasteboard)
    #expect(try await eventuallyShows(.text("copy D"), in: plugin.history))
    plugin.deactivate()
    #expect(try storedContents(in: directory) == [.text("copy D"), .text("copy C"), .text("copy B"), .text("copy A")])
}
