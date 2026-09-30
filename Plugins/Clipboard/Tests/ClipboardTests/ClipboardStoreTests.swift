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

    let errors = ErrorLog()
    let reloaded = makeHistory(directory: directory, key: key, errors: errors)
    #expect(reloaded.items == history.items)
    #expect(errors.messages.isEmpty)
    let image = try #require(reloaded.items.first { $0.kind == .image })
    #expect(reloaded.imageData(for: image) == png)
}

@MainActor
@Test func R09__a_wrong_key_or_a_damaged_file_starts_empty_and_logs_an_error() throws {
    let directory = try makeDirectory()
    let history = makeHistory(directory: directory, key: makeKey())
    history.record(.text("written with the first key"))

    let errors = ErrorLog()
    let wrongKey = makeHistory(directory: directory, key: makeKey(), errors: errors)
    #expect(wrongKey.items.isEmpty)
    #expect(errors.messages.count == 1)

    let list = try #require(try files(in: directory).first)
    try Data("damaged".utf8).write(to: list)
    let damaged = ErrorLog()
    let key = makeKey()
    let fresh = makeHistory(directory: directory, key: key, errors: damaged)
    #expect(fresh.items.isEmpty)
    #expect(damaged.messages.count == 1)

    // Recording still works and replaces the unreadable file.
    fresh.record(.text("after the damage"))
    #expect(makeHistory(directory: directory, key: key).items.map(\.content) == [.text("after the damage")])

    // No list file at all is simply an empty history, not an error.
    let none = ErrorLog()
    #expect(makeHistory(directory: try makeDirectory(), key: key, errors: none).items.isEmpty)
    #expect(none.messages.isEmpty)
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
    let reused = try HistoryKey.loadOrCreate(in: storage)
    #expect(bytes(of: reused) == bytes(of: created))
    #expect(makeHistory(directory: storage.directory, key: reused).items.map(\.content) == [.text("encrypted with the keychain key")])

    try storage.setKeychainData(Data([1, 2, 3]), for: HistoryKey.account)
    #expect(throws: HistoryKey.InvalidKeyError.self) { try HistoryKey.loadOrCreate(in: storage) }
    #expect(try storage.keychainData(for: HistoryKey.account) == Data([1, 2, 3]))
}
