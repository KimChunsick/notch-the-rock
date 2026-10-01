import CryptoKit
import Foundation
import NotchKit

/// The history on disk: the list in one file and every image in a file of its own, each sealed
/// with AES-GCM under the history key. Every file is mode 0600 and holds ciphertext only; the one
/// exception is the empty `oldHistoryMarkerName` file a key replacement keeps while it runs.
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
    /// be read or opened with this key, or when the directory cannot be listed.
    ///
    /// Only a read that finds no such file means no list was written: `fileExists` also says no
    /// when the directory cannot be searched, and taking that for a first run would let this
    /// session's list replace the stored one once access comes back.
    func loadList() throws -> [ClipItem] {
        let url = directory.appendingPathComponent(Self.listFileName)
        let sealed: Data
        do {
            sealed = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            // Image files are checked against the list next, so the directory must be listable.
            _ = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            return []
        }
        return try JSONDecoder().decode([ClipItem].self, from: open(sealed))
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
        try removeIfPresent(imageURL(id))
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
        try removeIfPresent(directory.appendingPathComponent(Self.listFileName))
    }

    /// Removes the file at `url`; only a file that is not there counts as removed, so a file that
    /// cannot be reached is reported instead of being taken for gone.
    private func removeIfPresent(_ url: URL) throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {}
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

extension ClipboardStore {
    /// An empty file in the directory while the history there is sealed with an old key being
    /// replaced: written before the new key is stored, removed once that history is deleted.
    static let oldHistoryMarkerName = "old-history-to-delete"

    /// Loads the history key and returns the store in `directory` with it. A keychain call can wait
    /// on the system, so run this off the main thread. When the key replaces an old one that cannot
    /// be read without asking, the old history's files are deleted, so the new history starts empty
    /// instead of unreadable.
    ///
    /// The marker makes that deletion survive an interruption: any later call that finds it deletes
    /// the old files, and until the marker is gone this throws, so no list is written under the new
    /// key beside them. A marker left by a new key that could not be stored is dropped without
    /// deleting anything when the old key turns out to be readable: its history is readable too.
    static func open(in directory: URL, keychain: some HistoryKeychain) throws -> (store: ClipboardStore, key: SymmetricKey, origin: HistoryKey.Origin) {
        let marker = directory.appendingPathComponent(oldHistoryMarkerName)
        let (key, origin) = try HistoryKey.load(from: keychain) {
            try Data().write(to: marker)
        }
        let store = ClipboardStore(directory: directory, key: key)
        if origin == .movedFromOldAccount {
            try store.removeIfPresent(marker)
        } else if try isPresent(marker) {
            try store.deleteAll()
            try store.removeIfPresent(marker)
        }
        return (store, key, origin)
    }

    /// Whether there is a file at `url`. Only a read that finds no such file says no, as in
    /// `loadList()`: a marker that cannot be reached is not taken for gone.
    private static func isPresent(_ url: URL) throws -> Bool {
        do {
            _ = try Data(contentsOf: url)
            return true
        } catch CocoaError.fileReadNoSuchFile {
            return false
        }
    }
}

/// The keychain calls the history key makes: `PluginStorage` in the app, a recording fake in tests.
protocol HistoryKeychain: Sendable {
    func keychainData(for account: String) throws(KeychainError) -> Data?
    func setKeychainData(_ data: Data, for account: String, access: KeychainAccess) throws(KeychainError)
    func deleteKeychainData(for account: String) throws(KeychainError)
}

extension PluginStorage: HistoryKeychain {}

/// The 256-bit history key, kept in the Keychain under the plugin's service (this Mac only), as an
/// item every application may read without a dialog. The app is signed without a team, so an item
/// tied to its signature made macOS ask again after every build; the user chose weaker protection
/// over that dialog (D-53).
enum HistoryKey {
    static let account = "history-key-2"
    /// Where the key was kept before, readable by the build that stored it only.
    static let legacyAccount = "history-key"

    /// How `load(from:)` got the key.
    enum Origin: Equatable, Sendable {
        /// It was under `account`.
        case stored
        /// There was none, so a new one is stored now.
        case created
        /// It was under `legacyAccount`, readable without asking, and is now under `account`.
        case movedFromOldAccount
        /// The key under `legacyAccount` cannot be read without asking, so a new one is stored
        /// under `account` and the history sealed with the old one cannot be opened.
        case replacedOldKeyThatNeedsAccess
    }

    /// The stored key's data does not hold a 256-bit key. It is left in place: replacing it would
    /// make the existing history unreadable for good.
    struct InvalidKeyError: Error, CustomStringConvertible {
        let byteCount: Int
        var description: String { "the history key in the keychain has \(byteCount) bytes instead of 32" }
    }

    /// The key under `account`; else the key under `legacyAccount` moved there; else a new one. A
    /// keychain failure on `account`, including one that needs access, is thrown instead of creating
    /// a key, so a temporarily unreadable key is never replaced. Only an old key that needs access is
    /// replaced: `willReplaceOldKey` runs, then the new key is stored, and the old item is then
    /// deleted when that needs no dialog. A throw from `willReplaceOldKey` stores nothing.
    static func load(from keychain: some HistoryKeychain, willReplaceOldKey: () throws -> Void) throws -> (key: SymmetricKey, origin: Origin) {
        if let data = try keychain.keychainData(for: account) {
            return (try key(from: data), .stored)
        }
        let legacy: Data?
        do {
            legacy = try keychain.keychainData(for: legacyAccount)
        } catch where error.needsAccess {
            try willReplaceOldKey()
            let key = try create(in: keychain)
            try? keychain.deleteKeychainData(for: legacyAccount)
            return (key, .replacedOldKeyThatNeedsAccess)
        }
        guard let legacy else {
            return (try create(in: keychain), .created)
        }
        let key = try key(from: legacy)
        try keychain.setKeychainData(legacy, for: account, access: .anyApplication)
        try? keychain.deleteKeychainData(for: legacyAccount)
        return (key, .movedFromOldAccount)
    }

    private static func key(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw InvalidKeyError(byteCount: data.count) }
        return SymmetricKey(data: data)
    }

    private static func create(in keychain: some HistoryKeychain) throws -> SymmetricKey {
        let key = SymmetricKey(size: .bits256)
        try keychain.setKeychainData(key.withUnsafeBytes { Data($0) }, for: account, access: .anyApplication)
        return key
    }
}
