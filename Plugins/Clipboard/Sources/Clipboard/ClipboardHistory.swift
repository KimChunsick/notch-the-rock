import AppKit
import CryptoKit
import Observation

/// The clipboard history, newest first, shared by the plugin, its tab and its settings page.
///
/// Rules: an identical repeat moves the existing entry to the top; pinned entries stay until they
/// are deleted; at most `unpinnedLimit` unpinned entries are kept and the oldest go first. Every
/// change is handed to a `HistoryWriter`, which writes the list in the background. Without a
/// writable store (no key, or a stored list that cannot be read) the history lives in memory,
/// image originals included. An image whose file cannot be written when an unreadable store is
/// reset stays in memory the same way, and out of the list on disk, until `saveUnsavedImages()`
/// writes it.
@MainActor
@Observable
final class ClipboardHistory {
    static let unpinnedLimit = 200

    private(set) var items: [ClipItem] = []
    /// A stored list that could not be read. It is left untouched, and nothing is written, until
    /// `resetUnreadableStore()`.
    private var unreadableStore: ClipboardStore?
    /// Image entries whose file could not be written. They stay in the list and copyable, and
    /// `saveUnsavedImages()` tries again.
    private(set) var unsavedImageIDs: Set<ClipItem.ID> = []
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private var writer: HistoryWriter?
    /// The PNG of each image entry that is not safely on disk: every image while there is no
    /// writable store, and with one, an image until its file and a list that refers to it are
    /// written. Dropped with its entry.
    @ObservationIgnored private var originals: [ClipItem.ID: Data] = [:]
    @ObservationIgnored private let logError: @MainActor (String) -> Void

    init(logError: @escaping @MainActor (String) -> Void) {
        self.logError = logError
    }

    /// Whether the stored history could not be read, so this session is kept in memory only.
    var isStoreUnreadable: Bool { unreadableStore != nil }

    /// Replaces the list with what `store` holds and saves every later change there. A list that
    /// exists but cannot be read leaves the history empty and in memory, and the store untouched.
    /// With nil the history keeps its entries in memory only.
    func open(_ store: ClipboardStore?) {
        flush()
        self.store = nil
        writer = nil
        unreadableStore = nil
        unsavedImageIDs = []
        guard let store else { return }
        originals = [:]
        do {
            items = try store.loadItems()
        } catch {
            items = []
            unreadableStore = store
            logError("could not read the clipboard history, keeping it untouched and this session in memory: \(error)")
            return
        }
        attach(store)
        do {
            try store.deleteImages(notIn: Set(items.map(\.id)))
        } catch {
            logError("could not remove unused clipboard images: \(error)")
        }
    }

    /// Deletes the unreadable stored history and saves the entries of this session in its place.
    /// Every entry stays; an image whose file cannot be written joins `unsavedImageIDs`. Later
    /// changes are saved again.
    func resetUnreadableStore() {
        guard let store = unreadableStore else { return }
        do {
            try store.deleteAll()
        } catch {
            logError("could not delete the unreadable clipboard history: \(error)")
            return
        }
        unreadableStore = nil
        attach(store)
        unsavedImageIDs = Set(originals.keys)
        saveUnsavedImages()
    }

    /// Writes the file of every image in `unsavedImageIDs`, then saves the list, which refers to
    /// the ones written. An image that still cannot be written stays unsaved, copyable from memory.
    func saveUnsavedImages() {
        guard let store else { return }
        for (id, png) in originals where unsavedImageIDs.contains(id) {
            do {
                try store.saveImage(png, for: id)
                unsavedImageIDs.remove(id)
            } catch {
                logError("could not save a copied image: \(error)")
            }
        }
        save()
    }

    /// Returns once every change so far is on disk.
    func flush() {
        writer?.flush()
        releaseSavedOriginals()
    }

    /// Records the pasteboard's current content unless it is excluded or empty.
    func record(from pasteboard: NSPasteboard) {
        if let capture = ClipCapture.read(from: pasteboard) {
            record(capture)
        }
    }

    func record(_ capture: ClipCapture, at date: Date = .now) {
        let content: ClipItem.Content
        var png: Data?
        switch capture {
        case .text(let text):
            content = .text(text)
        case .link(let url):
            content = .link(url)
        case .image(let data, let thumbnail):
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            content = .image(digest: digest, thumbnail: thumbnail)
            png = data
        }

        if let index = items.firstIndex(where: { $0.content.isSameClip(as: content) }) {
            var item = items.remove(at: index)
            item.date = date
            items.insert(item, at: 0)
            save()
            return
        }

        let item = ClipItem(id: UUID(), content: content, date: date, isPinned: false)
        if let png {
            // One file per image, written here before the list that refers to it.
            if let store {
                do {
                    try store.saveImage(png, for: item.id)
                } catch {
                    logError("could not save a copied image: \(error)")
                    return
                }
            } else {
                originals[item.id] = png
            }
        }
        items.insert(item, at: 0)
        dropUnpinnedOverLimit()
    }

    func setPinned(_ pinned: Bool, for id: ClipItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isPinned != pinned else { return }
        items[index].isPinned = pinned
        if pinned {
            save()
        } else {
            dropUnpinnedOverLimit()
        }
    }

    func delete(_ id: ClipItem.ID) {
        remove { $0.id == id }
    }

    /// Deletes every entry that is not pinned.
    func clearUnpinned() {
        remove { !$0.isPinned }
    }

    /// Entries whose text or URL contains `query`, ignoring case; every entry for a blank query.
    func matching(_ query: String) -> [ClipItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return items.filter { $0.text?.localizedCaseInsensitiveContains(query) == true }
    }

    /// The full PNG of an image entry, nil when it cannot be read.
    func imageData(for item: ClipItem) -> Data? {
        guard case .image = item.content else { return nil }
        if let png = originals[item.id] { return png }
        guard let store else {
            logError("the image of a clipboard entry is not in memory")
            return nil
        }
        do {
            return try store.imageData(for: item.id)
        } catch {
            logError("could not read a clipboard image: \(error)")
            return nil
        }
    }

    /// Puts `item` on `pasteboard` as its original type. The monitor then sees that content again
    /// and moves the entry to the top, so it is not added twice. Returns false when the image
    /// could not be read.
    @discardableResult
    func copy(_ item: ClipItem, to pasteboard: NSPasteboard) -> Bool {
        switch item.content {
        case .text(let text):
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .link(let url):
            pasteboard.clearContents()
            pasteboard.declareTypes([.URL, .string], owner: nil)
            pasteboard.setString(url, forType: .URL)
            pasteboard.setString(url, forType: .string)
        case .image:
            guard let png = imageData(for: item) else { return false }
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
        }
        return true
    }

    private func dropUnpinnedOverLimit() {
        var unpinned = items.filter { !$0.isPinned }.count
        guard unpinned > Self.unpinnedLimit else {
            save()
            return
        }
        // `items` is newest first, so the unpinned entries past the limit are the oldest.
        var dropped: Set<ClipItem.ID> = []
        for item in items.reversed() where !item.isPinned && unpinned > Self.unpinnedLimit {
            dropped.insert(item.id)
            unpinned -= 1
        }
        remove { dropped.contains($0.id) }
    }

    /// Removes matching entries and saves the list. Their image files are deleted only once that
    /// list is written; an interruption leaves at worst an unused image file, which the next
    /// `open(_:)` removes.
    private func remove(where shouldRemove: (ClipItem) -> Bool) {
        let removed = items.filter(shouldRemove)
        guard !removed.isEmpty else { return }
        items.removeAll(where: shouldRemove)
        let removedImages = Set(removed.filter { $0.kind == .image }.map(\.id))
        for id in removedImages {
            originals[id] = nil
            unsavedImageIDs.remove(id)
        }
        save(deletingImagesOf: removedImages)
    }

    /// Queues the list for writing. It leaves out the images in `unsavedImageIDs`, so the list on
    /// disk refers only to images whose file is written.
    private func save(deletingImagesOf removedImages: Set<ClipItem.ID> = []) {
        releaseSavedOriginals()
        writer?.save(items.filter { !unsavedImageIDs.contains($0.id) }, deletingImagesOf: removedImages)
    }

    /// Drops the PNG kept in memory for each image that a list written to disk refers to; such a
    /// list names only images whose file is written (see `save`).
    private func releaseSavedOriginals() {
        guard let writer, !originals.isEmpty else { return }
        let written = writer.writtenIDs
        for id in originals.keys where written.contains(id) {
            originals[id] = nil
        }
    }

    private func attach(_ store: ClipboardStore) {
        self.store = store
        let logError = logError
        writer = HistoryWriter(store: store) { message in
            Task { @MainActor in logError(message) }
        }
    }
}

extension ClipItem.Content {
    /// Whether both are the same copied content: equal text, equal URL or an image with the same
    /// digest (thumbnails are derived and not compared).
    func isSameClip(as other: ClipItem.Content) -> Bool {
        switch (self, other) {
        case let (.text(lhs), .text(rhs)), let (.link(lhs), .link(rhs)):
            lhs == rhs
        case let (.image(lhs, _), .image(rhs, _)):
            lhs == rhs
        default:
            false
        }
    }
}
