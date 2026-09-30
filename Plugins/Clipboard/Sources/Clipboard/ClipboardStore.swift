import CryptoKit
import Foundation
import NotchKit

/// The history on disk: the list in one file and every image in a file of its own, each sealed
/// with AES-GCM under the history key. Every file is mode 0600 and holds ciphertext only.
///
/// Images are kept apart so that recording a text does not rewrite every image, and an image is
/// written once when it is first copied. An image file is always written before any list names
/// it, so a list on disk never refers to an image that is not.
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

    /// The stored list, empty when none was written yet. Throws when the file cannot be read or
    /// opened with this key.
    func loadList() throws -> StoredList {
        let url = directory.appendingPathComponent(Self.listFileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return StoredList() }
        return try JSONDecoder().decode(StoredList.self, from: open(Data(contentsOf: url)))
    }

    func saveList(_ list: StoredList) throws {
        try write(JSONEncoder().encode(list), to: directory.appendingPathComponent(Self.listFileName))
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

    /// Deletes the list and every image file, for a history that can no longer be read.
    func deleteAll() throws {
        let list = directory.appendingPathComponent(Self.listFileName)
        if FileManager.default.fileExists(atPath: list.path) {
            try FileManager.default.removeItem(at: list)
        }
        for url in try imageURLs() {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// The entry id of every image file on disk, with the time the file was written.
    func imageFiles() throws -> [UUID: Date] {
        var files: [UUID: Date] = [:]
        for url in try imageURLs() {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            files[id] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        }
        return files
    }

    private func imageURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == Self.imageExtension }
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

/// What the list file holds.
///
/// Opening a store deletes only the image files that `removedImageIDs` names. Any other image file
/// that `items` does not name was written before a list write that failed or never ran, so it is
/// brought back as an entry rather than deleted.
struct StoredList: Codable, Equatable, Sendable {
    /// Newest first.
    var items: [ClipItem] = []
    /// Images whose entry was removed and whose file may still be on disk: each was named by the
    /// list this one replaces, or its file could not be deleted.
    var removedImageIDs: Set<UUID> = []
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
