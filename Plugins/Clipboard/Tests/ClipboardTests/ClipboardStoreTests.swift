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

/// Resetting deletes the unreadable files and saves what this session captured in a new store.
@MainActor
@Test func R09__resetting_an_unreadable_store_writes_a_new_one() throws {
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

    history.resetUnreadableStore()
    #expect(!history.isStoreUnreadable)
    history.flush()
    let names = try files(in: directory).map(\.lastPathComponent)
    #expect(names.count == 2)  // the new list and the new image
    #expect(!names.contains("\(oldImage.id.uuidString).\(ClipboardStore.imageExtension)"))

    let errors = ErrorLog()
    let reloaded = makeHistory(directory: directory, key: key, errors: errors)
    #expect(!reloaded.isStoreUnreadable)
    #expect(reloaded.items == history.items)
    #expect(errors.messages.isEmpty)
    let image = try #require(reloaded.items.first { $0.kind == .image })
    #expect(reloaded.imageData(for: image) == png)

    // Later changes are saved again.
    history.record(.link("https://example.com/after"))
    history.flush()
    #expect(makeHistory(directory: directory, key: key).items == history.items)
}

/// A reset whose image write fails (a full disk) keeps that entry in the list, pinned and copyable,
/// with its original in memory, and reports it. The list on disk leaves it out until its file is
/// written. A retry once the disk takes files again saves the image and a list that refers to it,
/// and only then lets the original go.
@MainActor
@Test func R09__a_reset_keeps_images_it_could_not_save_until_a_retry_saves_them() throws {
    let directory = try makeDirectory()
    let old = makeHistory(directory: directory, key: makeKey())
    old.record(.text("unreadable later"))
    old.flush()

    let key = makeKey()
    let fault = ImageWriteFault()
    let errors = ErrorLog()
    let history = ClipboardHistory(logError: errors.append)
    history.open(ClipboardStore(directory: directory, key: key) { try fault.write($0, to: $1) })
    #expect(history.isStoreUnreadable)
    let png = samplePNG(seed: 8)
    history.record(try #require(ClipCapture(png: png)))
    history.record(.text("kept after the reset"))
    let image = try #require(history.items.first { $0.kind == .image })
    history.setPinned(true, for: image.id)
    let captured = history.items
    errors.messages = []

    fault.isFull = true
    history.resetUnreadableStore()
    #expect(!history.isStoreUnreadable)
    #expect(history.items == captured)
    #expect(history.unsavedImageIDs == [image.id])
    #expect(errors.messages.count == 1)
    #expect(history.imageData(for: image) == png)
    let pasteboard = makePasteboard()
    defer { pasteboard.releaseGlobally() }
    #expect(history.copy(image, to: pasteboard))
    #expect(pasteboard.data(forType: .png) == png)

    history.flush()
    let imageFile = directory.appendingPathComponent(image.id.uuidString).appendingPathExtension(ClipboardStore.imageExtension)
    #expect(!FileManager.default.fileExists(atPath: imageFile.path))
    let saved = makeHistory(directory: directory, key: key)
    #expect(!saved.isStoreUnreadable)
    #expect(saved.items.map(\.content) == [.text("kept after the reset")])

    // A retry while the disk is still full keeps the entry as it is.
    history.saveUnsavedImages()
    #expect(history.unsavedImageIDs == [image.id])
    #expect(history.imageData(for: image) == png)

    fault.isFull = false
    history.saveUnsavedImages()
    #expect(history.unsavedImageIDs.isEmpty)
    history.flush()
    let reloaded = makeHistory(directory: directory, key: key)
    #expect(reloaded.items == history.items)
    #expect(reloaded.imageData(for: image) == png)

    // The original has left memory: without its file the image can no longer be read.
    try FileManager.default.removeItem(at: imageFile)
    #expect(history.imageData(for: image) == nil)
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

private func bytes(of key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

/// The real Keychain: the key is created once, reused afterwards, and never replaced when what is
/// stored cannot be used.
@MainActor
@Test func R09__the_history_key_lives_in_the_keychain() throws {
    let service = "com.notchtherock.clipboard.tests.\(UUID().uuidString)"
    let storage = try PluginStorage(
        directory: try makeDirectory(),
        defaultsSuiteName: "clipboard-tests.com.notchtherock.clipboard",
        keychainService: service
    )
    defer { try? storage.deleteKeychainData(for: HistoryKey.account) }
    #expect(try storage.keychainData(for: HistoryKey.account) == nil)

    let created = try HistoryKey.loadOrCreate(in: storage)
    #expect(created.bitCount == 256)
    #expect(try storage.keychainData(for: HistoryKey.account) == bytes(of: created))

    let history = makeHistory(directory: storage.directory, key: created)
    history.record(.text("encrypted with the keychain key"))
    history.flush()
    let reused = try HistoryKey.loadOrCreate(in: storage)
    #expect(bytes(of: reused) == bytes(of: created))
    #expect(makeHistory(directory: storage.directory, key: reused).items.map(\.content) == [.text("encrypted with the keychain key")])

    try storage.setKeychainData(Data([1, 2, 3]), for: HistoryKey.account)
    #expect(throws: HistoryKey.InvalidKeyError.self) { try HistoryKey.loadOrCreate(in: storage) }
    #expect(try storage.keychainData(for: HistoryKey.account) == Data([1, 2, 3]))
}
