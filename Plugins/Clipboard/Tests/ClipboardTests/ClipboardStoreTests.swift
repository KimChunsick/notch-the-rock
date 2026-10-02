import CryptoKit
import Foundation
import NotchKit
import Testing
@testable import Clipboard

/// Writes a text, a link and an image that carry a unique marker, then reads every byte of every
/// file in the storage directory: neither the marker (UTF-8, UTF-16) nor the image bytes appear.
@MainActor
@Test func R09__no_plaintext_of_any_entry_reaches_the_disk() throws {
    let directory = try makeDirectory()
    let history = makeHistory(directory: directory, key: makeKey())
    let marker = "R09-plaintext-marker-\(UUID().uuidString)"
    let png = samplePNG(seed: 7)
    history.record(.text("비밀 메모 \(marker)"))
    history.record(.link("https://example.com/\(marker)"))
    history.record(try #require(ClipCapture(png: png)))
    history.setPinned(true, for: try #require(history.items.last).id)

    let needles: [(String, Data)] = [
        ("UTF-8", Data(marker.utf8)),
        ("UTF-16LE", try #require(marker.data(using: .utf16LittleEndian))),
        ("UTF-16BE", try #require(marker.data(using: .utf16BigEndian))),
        ("PNG signature", Data([0x89, 0x50, 0x4E, 0x47])),
        ("image bytes", png.subdata(in: png.count / 2 ..< png.count / 2 + 32)),
    ]
    history.flush()
    let stored = try files(in: directory)
    #expect(stored.count == 2)  // the list and the image
    for file in stored {
        let bytes = try Data(contentsOf: file)
        for (name, needle) in needles {
            #expect(bytes.range(of: needle) == nil, "\(name) found in \(file.lastPathComponent)")
        }
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600, "\(file.lastPathComponent) has mode \(String(mode ?? 0, radix: 8))")
    }
}

@MainActor
@Test func R09__a_new_store_with_the_same_key_restores_the_list() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let png = samplePNG(seed: 3)
    let history = makeHistory(directory: directory, key: key)
    history.record(.text("여러 줄\n텍스트"))
    history.record(try #require(ClipCapture(png: png)))
    history.record(.link("https://example.com"))
    history.setPinned(true, for: history.items[1].id)
    history.flush()

    let errors = ErrorLog()
    let reloaded = makeHistory(directory: directory, key: key, errors: errors)
    #expect(reloaded.items == history.items)
    #expect(errors.messages.isEmpty)
    let image = try #require(reloaded.items.first { $0.kind == .image })
    #expect(reloaded.imageData(for: image) == png)
}

/// A list that cannot be read (another key, a damaged file) is never written over: the history
/// keeps new entries in memory only, including image originals, and leaves every stored file as it
/// was until the user resets it.
@MainActor
@Test func R09__an_unreadable_store_is_never_overwritten() throws {
    let directory = try makeDirectory()
    let first = makeHistory(directory: directory, key: makeKey())
    first.record(.text("written with the first key"))
    first.record(try #require(ClipCapture(png: samplePNG(seed: 1))))
    first.flush()
    let stored = try contents(of: directory)
    #expect(stored.count == 2)

    let errors = ErrorLog()
    let wrongKey = makeHistory(directory: directory, key: makeKey(), errors: errors)
    #expect(wrongKey.items.isEmpty)
    #expect(wrongKey.isStoreUnreadable)
    #expect(errors.messages.count == 1)
    let png = samplePNG(seed: 2)
    wrongKey.record(.text("captured while unreadable"))
    wrongKey.record(try #require(ClipCapture(png: png)))
    wrongKey.record(.link("https://example.com"))
    wrongKey.setPinned(true, for: wrongKey.items[2].id)
    wrongKey.delete(wrongKey.items[0].id)
    wrongKey.clearUnpinned()
    wrongKey.record(try #require(ClipCapture(png: png)))
    wrongKey.flush()
    #expect(wrongKey.items.map(\.kind) == [.image, .text])
    #expect(wrongKey.unsavedCount == 2)
    #expect(wrongKey.imageData(for: wrongKey.items[0]) == png)
    #expect(try contents(of: directory) == stored)

    // A damaged list is left alone the same way.
    let list = directory.appendingPathComponent(ClipboardStore.listFileName)
    try Data("damaged".utf8).write(to: list)
    let damagedFiles = try contents(of: directory)
    let damagedErrors = ErrorLog()
    let damaged = makeHistory(directory: directory, key: makeKey(), errors: damagedErrors)
    #expect(damaged.isStoreUnreadable)
    #expect(damagedErrors.messages.count == 1)
    damaged.record(.text("after the damage"))
    damaged.flush()
    #expect(damaged.items.map(\.content) == [.text("after the damage")])
    #expect(try contents(of: directory) == damagedFiles)

    // No list file at all is a first run: an empty history that is saved as usual.
    let none = ErrorLog()
    let fresh = try makeDirectory()
    let key = makeKey()
    let firstRun = makeHistory(directory: fresh, key: key, errors: none)
    #expect(firstRun.items.isEmpty)
    #expect(!firstRun.isStoreUnreadable)
    #expect(none.messages.isEmpty)
    firstRun.record(.text("first run"))
    firstRun.flush()
    #expect(makeHistory(directory: fresh, key: key).items.map(\.content) == [.text("first run")])
}

/// A list is missing only when reading it finds no such file in a directory that can be listed.
/// A directory that cannot be opened or listed, or a list that is a directory, makes the store
/// unreadable: nothing is written or cleaned up there until a reset, even once access comes back.
@MainActor
@Test func R09__a_store_that_cannot_be_accessed_is_not_taken_for_an_empty_one() throws {
    let manager = FileManager.default
    let directory = try makeDirectory()
    defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
    let key = makeKey()
    let first = makeHistory(directory: directory, key: key)
    first.record(.text("saved before access was lost"))
    first.record(try #require(ClipCapture(png: samplePNG(seed: 22))))
    first.flush()
    let saved = first.items
    let stored = try contents(of: directory)

    try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: directory.path)
    let errors = ErrorLog()
    let locked = makeHistory(directory: directory, key: key, errors: errors)
    #expect(locked.isStoreUnreadable)
    #expect(locked.items.isEmpty)
    #expect(errors.messages.count == 1)
    locked.record(.text("captured while access was lost"))
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    locked.flush()
    #expect(try contents(of: directory) == stored)
    #expect(makeHistory(directory: directory, key: key).items == saved)

    // A list that is a directory cannot be read either; the image file next to it stays.
    let blockedDirectory = try makeDirectory()
    try manager.createDirectory(
        at: blockedDirectory.appendingPathComponent(ClipboardStore.listFileName), withIntermediateDirectories: false
    )
    let stray = UUID()
    try ClipboardStore(directory: blockedDirectory, key: key).saveImage(samplePNG(seed: 23), for: stray)
    let blocked = makeHistory(directory: blockedDirectory, key: key)
    #expect(blocked.isStoreUnreadable)
    blocked.record(.text("captured next to a blocked list"))
    blocked.flush()
    #expect(try files(in: blockedDirectory).map(\.lastPathComponent) == [imageFile(for: stray, in: blockedDirectory).lastPathComponent])

    // No list file in a directory that cannot be listed is not a first run.
    let unlistedDirectory = try makeDirectory()
    defer { try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unlistedDirectory.path) }
    try manager.setAttributes([.posixPermissions: 0o300], ofItemAtPath: unlistedDirectory.path)
    let unlisted = makeHistory(directory: unlistedDirectory, key: key)
    #expect(unlisted.isStoreUnreadable)
    unlisted.record(.text("captured where nothing can be listed"))
    unlisted.flush()
    try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unlistedDirectory.path)
    #expect(try files(in: unlistedDirectory).isEmpty)
}

/// Resetting deletes the unreadable files and saves what this session captured in a new store.
@MainActor
@Test func R09__resetting_an_unreadable_store_writes_a_new_one() async throws {
    let directory = try makeDirectory()
    let old = makeHistory(directory: directory, key: makeKey())
    old.record(.text("unreadable later"))
    old.record(try #require(ClipCapture(png: samplePNG(seed: 4))))
    old.flush()
    let oldImage = try #require(old.items.first { $0.kind == .image })

    let key = makeKey()
    let history = makeHistory(directory: directory, key: key)
    #expect(history.isStoreUnreadable)
    let png = samplePNG(seed: 5)
    history.record(.text("kept after the reset"))
    history.record(try #require(ClipCapture(png: png)))
    history.setPinned(true, for: history.items[1].id)

    await history.resetUnreadableStore()
    // The reset saved with the key in the key file, never with the key the session had.
    let saved = try storedKey(in: directory)
    #expect(!history.isStoreUnreadable)
    history.flush()
    let names = try files(in: directory).map(\.lastPathComponent)
    #expect(names.count == 4)  // the new list, the new image, the key file the reset created and the lock file
    #expect(!names.contains("\(oldImage.id.uuidString).\(ClipboardStore.imageExtension)"))

    let errors = ErrorLog()
    let reloaded = makeHistory(directory: directory, key: saved, errors: errors)
    #expect(!reloaded.isStoreUnreadable)
    #expect(reloaded.items == history.items)
    #expect(errors.messages.isEmpty)
    let image = try #require(reloaded.items.first { $0.kind == .image })
    #expect(reloaded.imageData(for: image) == png)

    // Later changes are saved again.
    history.record(.link("https://example.com/after"))
    history.flush()
    #expect(makeHistory(directory: directory, key: saved).items == history.items)
}

/// A reset deletes the image files before the list. When it stops partway, here at an image file
/// that cannot be deleted, the unreadable list is still on disk: the store stays unreadable, in
/// this session and the next, and no image file comes back as an entry. Once every file can go,
/// the reset finishes and saves this session.
@MainActor
@Test func R09__an_interrupted_reset_leaves_the_store_unreadable() async throws {
    let directory = try makeDirectory()
    let old = makeHistory(directory: directory, key: makeKey())
    old.record(try #require(ClipCapture(png: samplePNG(seed: 20))))
    old.record(try #require(ClipCapture(png: samplePNG(seed: 21))))
    old.record(.text("unreadable later"))
    old.flush()
    let locked = imageFile(for: try #require(old.items.first { $0.kind == .image }).id, in: directory)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    let list = directory.appendingPathComponent(ClipboardStore.listFileName)
    let unreadableList = try Data(contentsOf: list)

    let key = makeKey()
    let errors = ErrorLog()
    let history = ClipboardHistory(logError: errors.append)
    history.open(ClipboardStore(directory: directory, key: key))
    history.record(.text("this session"))
    errors.messages = []
    await history.resetUnreadableStore()
    history.flush()
    #expect(history.isStoreUnreadable)
    #expect(errors.messages.count == 1)
    #expect(try Data(contentsOf: list) == unreadableList)

    let reopened = makeHistory(directory: directory, key: key)
    #expect(reopened.isStoreUnreadable)
    #expect(reopened.items.isEmpty)
    #expect(FileManager.default.fileExists(atPath: locked.path))

    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
    await history.resetUnreadableStore()
    // The reset saved with the key in the key file, never with the key the session had.
    let saved = try storedKey(in: directory)
    #expect(!history.isStoreUnreadable)
    history.flush()
    #expect(Set(try files(in: directory).map(\.lastPathComponent)) == [ClipboardStore.listFileName, ClipboardStore.openingLockName, HistoryKey.fileName])
    #expect(makeHistory(directory: directory, key: saved).items.map(\.content) == [.text("this session")])
}

/// An image file that the list on disk does not name was never saved: opening the store deletes
/// it, and it does not come back as an entry.
@MainActor
@Test func R09__opening_a_store_deletes_image_files_its_list_does_not_name() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let png = samplePNG(seed: 14)
    let history = makeHistory(directory: directory, key: key)
    history.record(.text("on disk"))
    history.record(try #require(ClipCapture(png: png)))
    history.flush()
    let stray = UUID()
    try ClipboardStore(directory: directory, key: key).saveImage(samplePNG(seed: 15), for: stray)

    let errors = ErrorLog()
    let reopened = makeHistory(directory: directory, key: key, errors: errors)
    #expect(reopened.items == history.items)
    #expect(errors.messages.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: imageFile(for: stray, in: directory).path))
    let image = try #require(reopened.items.first { $0.kind == .image })
    #expect(reopened.imageData(for: image) == png)
}

/// An entry is saved once its image file and a list that names it are both on disk. Here the
/// image file is written but the list is not: the entry stays in the history and counts as not
/// saved until a later flush writes the list, after which a new history on the store restores it.
@MainActor
@Test func R09__an_entry_is_unsaved_until_a_list_that_names_it_is_written() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let fault = WriteFault()
    let history = ClipboardHistory(logError: { _ in })
    history.open(ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) })
    history.record(.text("saved"))
    history.flush()
    let saved = try #require(history.items.first)
    #expect(history.unsavedCount == 0)

    fault.failsList = true
    let png = samplePNG(seed: 16)
    history.record(try #require(ClipCapture(png: png)))
    let image = try #require(history.items.first)
    history.flush()
    #expect(FileManager.default.fileExists(atPath: imageFile(for: image.id, in: directory).path))
    #expect(history.unsavedCount == 1)
    #expect(history.showsUnsavedNotice(at: .now + ClipboardHistory.unsavedNoticeDelay))
    #expect(try ClipboardStore(directory: directory, key: key).loadList().map(\.id) == [saved.id])

    fault.failsList = false
    history.flush()
    #expect(history.unsavedCount == 0)
    #expect(!history.showsUnsavedNotice(at: .distantFuture))
    let reloaded = makeHistory(directory: directory, key: key)
    #expect(reloaded.items == history.items)
    #expect(reloaded.imageData(for: image) == png)
}

/// The count measures the list last written, so an entry whose list is queued or still being
/// written is not saved yet. The tab mentions it only once the count has stayed above zero for
/// `unsavedNoticeDelay`, so a write in progress does not flash a notice on every copy.
@MainActor
@Test func R09__an_entry_counts_as_unsaved_while_its_list_is_being_written() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let gate = WriteGate()
    defer { gate.open() }
    let clock = ManualClock()
    let history = ClipboardHistory(logError: { _ in }, now: { clock.now })
    history.open(ClipboardStore(directory: directory, key: key) { try gate.write($0, to: $1) })
    #expect(history.unsavedSince == nil)

    history.record(.text("first copy"))
    #expect(history.unsavedCount == 1)
    let since = try #require(history.unsavedSince)
    #expect(since == clock.now)
    #expect(!history.showsUnsavedNotice(at: since + 1.9))
    #expect(history.showsUnsavedNotice(at: since + ClipboardHistory.unsavedNoticeDelay))

    // Another change while the count stays above zero keeps the moment it rose.
    clock.now += 1
    history.record(.text("second copy"))
    #expect(history.unsavedCount == 2)
    #expect(history.unsavedSince == since)

    gate.open()
    history.flush()
    #expect(history.unsavedCount == 0)
    #expect(history.unsavedSince == nil)
    #expect(!history.showsUnsavedNotice(at: since + 60))
    #expect(try ClipboardStore(directory: directory, key: key).loadList() == history.items)
}

/// A list that could not be written is kept: the next change writes again, its newer list
/// winning, and so does the next flush when nothing changed.
@MainActor
@Test func R09__a_failed_list_is_written_again_on_the_next_change_or_flush() async throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let fault = WriteFault()
    let store = ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) }
    let history = ClipboardHistory(logError: { _ in })
    history.open(store)

    fault.failsList = true
    history.record(.text("first"))
    history.flush()
    #expect(try store.loadList().isEmpty)
    #expect(history.unsavedCount == 1)

    // The next change, without a flush.
    fault.failsList = false
    history.record(.text("second"))
    let changed = ContinuousClock.now
    while try store.loadList().count < 2, ContinuousClock.now - changed < .seconds(2) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try store.loadList().map(\.content) == [.text("second"), .text("first")])

    // The next flush, with no change after the failure.
    fault.failsList = true
    history.setPinned(true, for: try #require(history.items.last).id)
    history.flush()
    #expect(try store.loadList().allSatisfy { !$0.isPinned })
    fault.failsList = false
    history.flush()
    #expect(try store.loadList() == history.items)
    #expect(history.unsavedCount == 0)
}

/// Reopening the store, as turning the clipboard feature off and on does, keeps what was not saved
/// as well as what was: an image whose file could not be written and the entries of a list that
/// could not be written stay in the history, in memory while the disk refuses them, and are saved
/// by the first reopening that can write them.
@MainActor
@Test func R09__reopening_keeps_unsaved_entries_and_saves_them() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let fault = WriteFault()
    let errors = ErrorLog()
    let history = ClipboardHistory(logError: errors.append)
    history.open(ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) })
    history.record(.text("saved"))
    history.flush()
    let saved = history.items

    fault.failsImages = true
    let png = samplePNG(seed: 17)
    history.record(try #require(ClipCapture(png: png)))
    let withoutFile = try #require(history.items.first)
    #expect(errors.messages.count == 1)
    #expect(history.imageData(for: withoutFile) == png)
    fault.failsImages = false
    fault.failsList = true
    history.record(try #require(ClipCapture(png: samplePNG(seed: 18))))
    let withoutList = try #require(history.items.first)
    history.record(.text("not saved"))
    history.flush()
    #expect(history.items.count == 4)
    #expect(history.unsavedCount == 3)
    #expect(!FileManager.default.fileExists(atPath: imageFile(for: withoutFile.id, in: directory).path))
    #expect(FileManager.default.fileExists(atPath: imageFile(for: withoutList.id, in: directory).path))

    let captured = history.items

    history.open(ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) })
    history.flush()
    #expect(history.items == captured)
    #expect(history.unsavedCount == 3)
    #expect(try ClipboardStore(directory: directory, key: key).loadList() == saved)

    fault.failsList = false
    history.open(ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) })
    history.flush()
    #expect(history.items == captured)
    #expect(history.unsavedCount == 0)
    #expect(makeHistory(directory: directory, key: key).items == captured)
    #expect(try files(in: directory).count == 3)
}

/// A reset saves this session under the same rule: an image whose file cannot be written stays in
/// the history, copyable from memory and counted as not saved, and the list on disk leaves it out.
/// Reopening the store keeps it and writes its file and a list that names it.
@MainActor
@Test func R09__a_reset_keeps_an_image_it_could_not_save_in_memory_only() async throws {
    let directory = try makeDirectory()
    let old = makeHistory(directory: directory, key: makeKey())
    old.record(.text("unreadable later"))
    old.flush()

    let key = makeKey()
    let fault = WriteFault()
    let errors = ErrorLog()
    let history = ClipboardHistory(logError: errors.append)
    history.open(ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) })
    let png = samplePNG(seed: 19)
    history.record(try #require(ClipCapture(png: png)))
    history.record(.text("kept after the reset"))
    let image = try #require(history.items.first { $0.kind == .image })
    history.setPinned(true, for: image.id)
    let captured = history.items
    errors.messages = []

    fault.failsImages = true
    await history.resetUnreadableStore()
    // The reset saved with the key in the key file, never with the key the session had.
    let saved = try storedKey(in: directory)
    history.flush()
    #expect(!history.isStoreUnreadable)
    #expect(history.items == captured)
    #expect(history.unsavedCount == 1)
    #expect(errors.messages.count == 1)
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    #expect(history.copy(image, to: pasteboard))
    #expect(pasteboard.data(forType: .png) == png)
    #expect(try ClipboardStore(directory: directory, key: saved).loadList().map(\.content) == [.text("kept after the reset")])

    fault.failsImages = false
    history.record(.link("https://example.com"))
    history.flush()
    #expect(history.unsavedCount == 1)
    let beforeReopening = history.items
    history.open(ClipboardStore(directory: directory, key: saved))
    history.flush()
    #expect(history.items == beforeReopening)
    #expect(history.unsavedCount == 0)
    #expect(makeHistory(directory: directory, key: saved).items == beforeReopening)
    #expect(history.imageData(for: image) == png)
}

/// An image file goes only after a list without its entry is on disk: when that write fails the
/// file stays, so the list still on disk keeps a readable image.
@MainActor
@Test func R09__image_files_stay_when_the_list_write_fails() throws {
    let directory = try makeDirectory()
    let key = makeKey()
    let png = samplePNG(seed: 6)
    let history = makeHistory(directory: directory, key: key)
    history.record(try #require(ClipCapture(png: png)))
    history.record(.text("next to the image"))
    history.flush()
    let image = try #require(history.items.first { $0.kind == .image })
    let imageFile = directory.appendingPathComponent(image.id.uuidString).appendingPathExtension(ClipboardStore.imageExtension)
    let list = directory.appendingPathComponent(ClipboardStore.listFileName)
    let savedList = try Data(contentsOf: list)

    // A non-empty folder in place of the list makes the next list write fail.
    try FileManager.default.removeItem(at: list)
    try FileManager.default.createDirectory(at: list, withIntermediateDirectories: false)
    try Data("blocker".utf8).write(to: list.appendingPathComponent("blocker"))
    history.delete(image.id)
    history.flush()
    #expect(FileManager.default.fileExists(atPath: imageFile.path))

    try FileManager.default.removeItem(at: list)
    try savedList.write(to: list)
    let reloaded = makeHistory(directory: directory, key: key)
    let restored = try #require(reloaded.items.first { $0.id == image.id })
    #expect(reloaded.imageData(for: restored) == png)
}

/// An image copied again while the key loads merges into the stored entry with that image. When
/// the stored file is missing or damaged, the copy's PNG is written in its place, so the entry
/// copies again; when that write fails too, the PNG stays in memory and the failure is logged.
@MainActor
@Test func R09__an_image_copied_again_repairs_a_missing_or_damaged_stored_file() throws {
    let png = samplePNG(seed: 4)
    for damage in ["missing", "damaged", "missing on a full disk"] {
        let comment = Comment(rawValue: damage)
        let directory = try makeDirectory()
        let key = makeKey()
        let stored = makeHistory(directory: directory, key: key)
        let id = stored.record(.image(png: png, thumbnail: png))
        stored.flush()
        let file = imageFile(for: id, in: directory)
        if damage == "damaged" {
            try Data("damaged".utf8).write(to: file)
        } else {
            try FileManager.default.removeItem(at: file)
        }
        let fault = WriteFault()
        fault.failsImages = damage.hasSuffix("full disk")
        let errors = ErrorLog()
        let history = ClipboardHistory(logError: errors.append)
        history.record(.image(png: png, thumbnail: png))

        history.open(ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) })
        history.flush()

        #expect(history.items.map(\.id) == [id], comment)
        let entry = try #require(history.items.first, comment)
        let pasteboard = makePasteboard()
        #expect(history.copy(entry, to: pasteboard), comment)
        #expect(pasteboard.data(forType: .png) == png, comment)
        pasteboard.releaseGlobally()
        if fault.failsImages {
            #expect(errors.messages.contains { $0.contains("keeping it in memory") }, comment)
            #expect(history.unsavedCount == 1, comment)
        } else {
            #expect(try ClipboardStore(directory: directory, key: key).imageData(for: id) == png, comment)
            #expect(history.unsavedCount == 0, comment)
        }
    }
}
