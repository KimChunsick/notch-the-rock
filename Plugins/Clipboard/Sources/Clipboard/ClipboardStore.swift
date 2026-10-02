import CryptoKit
import Foundation
import NotchKit

/// The history on disk: the list in one file and every image in a file of its own, each sealed
/// with AES-GCM under the history key. Every file is mode 0600 and holds ciphertext only; the
/// exceptions are the key file `HistoryKey.fileName` beside them and the empty
/// `oldHistoryMarkerName` file a new key keeps while it runs.
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
    /// An empty file in the directory while the history there may be sealed with a key that is not
    /// the one in the key file: written before a new key file is created, removed once that history
    /// is deleted.
    static let oldHistoryMarkerName = "old-history-to-delete"

    /// What `open(in:)` returns: the store, the key it seals with, how that key was got, and
    /// whether a history sealed with another key was deleted.
    typealias Opened = (store: ClipboardStore, key: SymmetricKey, origin: HistoryKey.Origin, removedOldHistory: Bool)

    /// Loads the history key from the key file in `directory`, creating one when there is none or
    /// when the file there is not trusted, and returns the store in `directory` with it. It reads
    /// and writes the disk, so run it off the main thread. A new key cannot open a history sealed
    /// before it (the one from when the key was kept in the keychain, or one sealed with a
    /// distrusted key file's key), so that history's files are deleted and the new history starts
    /// empty instead of unreadable. The keychain is never read, written or deleted.
    ///
    /// The marker makes that deletion survive an interruption: any later call that finds it deletes
    /// the files there when their list does not open with the key in the key file, and until the
    /// marker is gone this throws, so no list is written under the new key beside them. A list that
    /// opens with that key is that key's history, whatever left the marker: it is kept, and only the
    /// marker goes.
    static func open(in directory: URL) throws -> Opened {
        let marker = directory.appendingPathComponent(oldHistoryMarkerName)
        let (key, origin) = try HistoryKey.load(in: directory) {
            try Data().write(to: marker)
        }
        let store = ClipboardStore(directory: directory, key: key)
        var removedOldHistory = false
        if try isPresent(marker) {
            if try !store.listOpensWithKey() {
                try store.deleteAll()
                removedOldHistory = true
            }
            try store.removeIfPresent(marker)
        }
        return (store, key, origin, removedOldHistory)
    }

    /// Whether the stored list opens with this key, true when no list was written. Throws when the
    /// list cannot be read, so a list out of reach is never taken for one sealed with another key.
    /// Only decryption counts: a list that opens but cannot be decoded is this key's.
    private func listOpensWithKey() throws -> Bool {
        let sealed: Data
        do {
            sealed = try Data(contentsOf: directory.appendingPathComponent(Self.listFileName))
        } catch CocoaError.fileReadNoSuchFile {
            return true
        }
        return (try? open(sealed)) != nil
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

/// The 256-bit history key, kept in the file `fileName` in the plugin's own folder: a regular file
/// of this user with mode 0600, so only this user's processes can read it, the history beside it
/// staying encrypted. The key was kept in the keychain before; macOS refused it to every new build
/// of the app, which is signed without a team, so the user chose the file (D-80).
enum HistoryKey {
    static let fileName = "history.key"

    /// How `load(in:willCreate:)` got the key.
    enum Origin: Equatable, Sendable {
        /// It was in the key file.
        case stored
        /// There was no key file, so a new key file holds a new key.
        case created
        /// What was at the key file's name was not a private regular file of this user holding a
        /// key (another mode or owner, a symlink, a directory, another size), so a new key file
        /// replaced it.
        case replacedUntrustedFile
    }

    /// What is at the key file's name.
    private enum Entry {
        case missing
        case untrusted
        case key(SymmetricKey)
    }

    /// The key in the key file; else, after `willCreate` runs, a new key in a new key file that
    /// replaces anything untrusted there. A throw from `willCreate` creates nothing. A key file that
    /// cannot be read for another reason (an I/O error) is thrown, never replaced, so a key that is
    /// only out of reach for now does not make its history unreadable.
    static func load(in directory: URL, willCreate: () throws -> Void) throws -> (key: SymmetricKey, origin: Origin) {
        let url = directory.appendingPathComponent(fileName)
        let isUntrusted: Bool
        switch try read(url) {
        case .key(let key):
            return (key, .stored)
        case .missing:
            isUntrusted = false
        case .untrusted:
            isUntrusted = true
        }
        try willCreate()
        if isUntrusted {
            // Removes the entry itself: a symlink goes, never what it points to.
            try FileManager.default.removeItem(at: url)
        }
        if let key = try create(at: url) {
            return (key, isUntrusted ? .replacedUntrustedFile : .created)
        }
        // Another opening created the key file first: its key is the history's.
        guard case .key(let key) = try read(url) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return (key, .stored)
    }

    /// The key in the file at `url` when that is a regular file of this user with mode 0600 holding
    /// 32 bytes. `lstat` looks at the entry itself, so a symlink is untrusted wherever it points.
    /// The file is then opened without following a link or waiting (a FIFO would block) and checked
    /// again, so an entry swapped in between is not read either.
    private static func read(_ url: URL) throws -> Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return .missing }
            throw posixError(url)
        }
        guard isPrivateFile(info) else { return .untrusted }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { return .untrusted }
            throw posixError(url)
        }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0 else { throw posixError(url) }
        guard isPrivateFile(info), info.st_size == 32 else { return .untrusted }
        var bytes = [UInt8](repeating: 0, count: 33)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count >= 0 else { throw posixError(url) }
        guard count == 32 else { return .untrusted }
        return .key(SymmetricKey(data: Data(bytes[..<32])))
    }

    private static func isPrivateFile(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_mode & 0o7777 == 0o600 && info.st_uid == geteuid()
    }

    /// Writes a new key to a new file beside `url`, created with mode 0600 so it is never readable by
    /// others, then links it at `url`: the key file appears whole or not at all, and an existing one
    /// is never overwritten. Returns nil when a key file appeared at `url` meanwhile.
    private static func create(at url: URL) throws -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(fileName).\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError(temporary) }
        defer { unlink(temporary.path) }
        let written = key.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        let isWritten = written == 32 && fsync(descriptor) == 0
        let failure = written == 32 || written < 0 ? errno : EIO
        close(descriptor)
        guard isWritten else { throw posixError(temporary, code: failure) }
        guard link(temporary.path, url.path) == 0 else {
            if errno == EEXIST { return nil }
            throw posixError(url)
        }
        return key
    }

    private static func posixError(_ url: URL, code: Int32 = errno) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path])
    }
}
