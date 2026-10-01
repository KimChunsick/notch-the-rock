import CryptoKit
import Foundation
import NotchKit

/// The history on disk: the list in one file and every image in a file of its own, each sealed
/// with AES-GCM under the history key. Every file is mode 0600 and holds ciphertext only.
///
/// Images are kept apart so that recording a text does not rewrite every image, and an image is
/// written once when it is first copied. An image file is always written before any list names
/// it, so a list on disk never refers to an image that is not. An image file that the list does
/// not name was never saved, or belongs to a removed entry.
struct ClipboardStore: Sendable {
    static let listFileName = "history.sealed"
    static let imageExtension = "image"

    let directory: URL
    private let key: SymmetricKey
    private let writeFile: @Sendable (Data, URL) throws -> Void

    /// `writeFile` puts sealed bytes at a URL; tests pass one that fails like a full disk.
    init(
        directory: URL,
        key: SymmetricKey,
        writeFile: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    ) {
        self.directory = directory
        self.key = key
        self.writeFile = writeFile
    }

    /// The stored list, newest first, empty when none was written yet. Throws when the file cannot
    /// be read or opened with this key.
    func loadList() throws -> [ClipItem] {
        let url = directory.appendingPathComponent(Self.listFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ClipItem].self, from: open(Data(contentsOf: url)))
    }

    func saveList(_ items: [ClipItem]) throws {
        try write(JSONEncoder().encode(items), to: directory.appendingPathComponent(Self.listFileName))
    }

    func saveImage(_ png: Data, for id: UUID) throws {
        try write(png, to: imageURL(id))
    }

    func imageData(for id: UUID) throws -> Data {
        try open(Data(contentsOf: imageURL(id)))
    }

    func deleteImage(for id: UUID) throws {
        let url = imageURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Deletes every image file whose entry id is not in `kept`.
    func deleteImages(except kept: Set<UUID>) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where url.pathExtension == Self.imageExtension {
            if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent), kept.contains(id) { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Deletes every image file and then the list, for a history that can no longer be read. The
    /// list goes last: a deletion that stops partway leaves it in place, so the store stays
    /// unreadable and none of its remaining image files is loaded as a new entry.
    func deleteAll() throws {
        try deleteImages(except: [])
        let list = directory.appendingPathComponent(Self.listFileName)
        if FileManager.default.fileExists(atPath: list.path) {
            try FileManager.default.removeItem(at: list)
        }
    }

    private func imageURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.imageExtension)
    }

    private func write(_ plaintext: Data, to url: URL) throws {
        // `combined` is nil only for nonces of a non-standard size; seal(_:using:) uses 12 bytes.
        let sealed = try AES.GCM.seal(plaintext, using: key).combined!
        try writeFile(sealed, url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func open(_ sealed: Data) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: key)
    }
}

/// The 256-bit history key, kept in the Keychain under the plugin's service (this Mac only).
enum HistoryKey {
    static let account = "history-key"

    /// The stored key's data does not hold a 256-bit key. It is left in place: replacing it would
    /// make the existing history unreadable for good.
    struct InvalidKeyError: Error, CustomStringConvertible {
        let byteCount: Int
        var description: String { "the history key in the keychain has \(byteCount) bytes instead of 32" }
    }

    /// The stored key, or a new one stored now when the Keychain has none. A Keychain failure is
    /// thrown instead of creating a key, so a temporarily unreadable key is never replaced.
    static func loadOrCreate(in storage: PluginStorage) throws -> SymmetricKey {
        if let data = try storage.keychainData(for: account) {
            guard data.count == 32 else { throw InvalidKeyError(byteCount: data.count) }
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        try storage.setKeychainData(key.withUnsafeBytes { Data($0) }, for: account)
        return key
    }
}
