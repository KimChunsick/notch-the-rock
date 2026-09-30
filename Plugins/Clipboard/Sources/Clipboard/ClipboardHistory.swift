import AppKit
import CryptoKit
import Observation

/// The clipboard history, newest first, shared by the plugin, its tab and its settings page.
///
/// Rules: an identical repeat moves the existing entry to the top; pinned entries stay until they
/// are deleted; at most `unpinnedLimit` unpinned entries are kept and the oldest go first. Every
/// change is handed to a `HistoryWriter`, which writes the list in the background. Without a
/// writable store (no key, or a stored list that cannot be read) the history lives in memory,
/// image originals included.
///
/// An image is saved once its file is written and a list on disk names it; the file always comes
/// first. The images of an unreadable store's session stay in memory, and in `unsavedImageIDs`,
/// until both hold after the reset. A list write that fails is written again later; until then a
/// restart loses the changes since the last list on disk (texts, pins, deletions), but not an
/// image whose file is written: `open(_:)` brings it back as an unpinned entry.
@MainActor
@Observable
final class ClipboardHistory {
    static let unpinnedLimit = 200

    private(set) var items: [ClipItem] = []
    /// A stored list that could not be read. It is left untouched, and nothing is written, until
    /// `resetUnreadableStore()`.
    private var unreadableStore: ClipboardStore?
    /// Image entries of an unreadable store's session that are not saved yet after the reset: their
    /// file is not written, or no list on disk names them. They stay in the list and copyable from
    /// memory, and `saveUnsavedImages()` tries again.
    private(set) var unsavedImageIDs: Set<ClipItem.ID> = []
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private var writer: HistoryWriter?
    /// The PNG of each image entry that is not saved: every image while there is no writable
    /// store, and with one, an image until its file is written and a list on disk names it.
    /// Dropped with its entry.
    @ObservationIgnored private var originals: [ClipItem.ID: Data] = [:]
    /// Images whose file is not written yet. The lists handed to the writer leave them out.
    @ObservationIgnored private var imagesWithoutFile: Set<ClipItem.ID> = []
    @ObservationIgnored private let logError: @MainActor (String) -> Void

    init(logError: @escaping @MainActor (String) -> Void) {
        self.logError = logError
    }

    /// Whether the stored history could not be read, so this session is kept in memory only.
    var isStoreUnreadable: Bool { unreadableStore != nil }

    /// Replaces the list with what `store` holds and saves every later change there. A list that
    /// exists but cannot be read leaves the history empty and in memory, and the store untouched.
    /// With nil the history keeps its entries in memory only.
    ///
    /// Of the image files no stored entry names, only those the list marks as removed are deleted;
    /// the others were written before a list write that failed or never ran, and come back as
    /// unpinned entries dated by their file.
    func open(_ store: ClipboardStore?) {
        flush()
        self.store = nil
        writer = nil
        unreadableStore = nil
        unsavedImageIDs = []
        imagesWithoutFile = []
        guard let store else { return }
        originals = [:]
        let list: StoredList
        do {
            list = try store.loadList()
        } catch {
            items = []
            unreadableStore = store
            logError("could not read the clipboard history, keeping it untouched and this session in memory: \(error)")
            return
        }
        items = list.items
        var undeleted: Set<ClipItem.ID> = []
        for id in list.removedImageIDs {
            do {
                try store.deleteImage(for: id)
            } catch {
                logError("could not delete a clipboard image: \(error)")
                undeleted.insert(id)
            }
        }
        attach(store, listedIDs: Set(items.map(\.id)), removedImages: undeleted)
        recoverUnlistedImages(from: store, removed: list.removedImageIDs)
    }

    /// Deletes the unreadable stored history and saves the entries of this session in its place.
    /// Every entry stays; an image stays in `unsavedImageIDs` until it is saved. Later changes are
    /// saved again.
    func resetUnreadableStore() {
        guard let store = unreadableStore else { return }
        do {
            try store.deleteAll()
        } catch {
            logError("could not delete the unreadable clipboard history: \(error)")
            return
        }
        unreadableStore = nil
        attach(store, listedIDs: [], removedImages: [])
        imagesWithoutFile = Set(originals.keys)
        saveUnsavedImages()
    }

    /// Writes the file of every image that has none yet, then saves the list, which names the ones
    /// written, and waits for it. An image stays unsaved, copyable from memory, until a list that
    /// names it is on disk.
    func saveUnsavedImages() {
        guard let store else { return }
        for id in imagesWithoutFile {
            guard let png = originals[id] else { continue }
            do {
                try store.saveImage(png, for: id)
                imagesWithoutFile.remove(id)
            } catch {
                logError("could not save a copied image: \(error)")
            }
        }
        save()
        flush()
    }

    /// Returns once every change so far has been tried on disk, writing again a list whose write
    /// failed.
    func flush() {
        writer?.flush()
        refreshUnsavedImages()
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
            content = .image(digest: Self.digest(of: data), thumbnail: thumbnail)
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
            imagesWithoutFile.remove(id)
        }
        save(deletingImagesOf: removedImages)
    }

    /// Queues the list for writing. It leaves out the images without a file, so a list on disk
    /// names only images whose file is written.
    private func save(deletingImagesOf removedImages: Set<ClipItem.ID> = []) {
        refreshUnsavedImages()
        writer?.save(items.filter { !imagesWithoutFile.contains($0.id) }, deletingImagesOf: removedImages)
    }

    /// Drops the PNG kept in memory for each image that the list on disk names, whose file is
    /// therefore written (see `save`), and marks the others unsaved.
    private func refreshUnsavedImages() {
        guard let writer else { return }
        let listed = writer.writtenIDs
        for id in originals.keys where listed.contains(id) {
            originals[id] = nil
        }
        let unsaved = Set(originals.keys)
        if unsaved != unsavedImageIDs {
            unsavedImageIDs = unsaved
        }
    }

    /// Adds an entry for every image file that neither `items` nor `removed` names, newest first by
    /// the time its file was written, and saves the list that names them.
    private func recoverUnlistedImages(from store: ClipboardStore, removed: Set<ClipItem.ID>) {
        let files: [ClipItem.ID: Date]
        do {
            files = try store.imageFiles()
        } catch {
            logError("could not look for clipboard images to recover: \(error)")
            return
        }
        let listed = Set(items.map(\.id))
        var recovered = false
        for (id, date) in files where !listed.contains(id) && !removed.contains(id) {
            let capture: ClipCapture?
            do {
                capture = ClipCapture(png: try store.imageData(for: id))
            } catch {
                logError("could not read a clipboard image to recover: \(error)")
                continue
            }
            guard case .image(let png, let thumbnail)? = capture else {
                logError("a clipboard image to recover is not an image")
                continue
            }
            let item = ClipItem(id: id, content: .image(digest: Self.digest(of: png), thumbnail: thumbnail), date: date, isPinned: false)
            items.insert(item, at: items.firstIndex { $0.date < date } ?? items.endIndex)
            recovered = true
        }
        if recovered {
            dropUnpinnedOverLimit()
        }
    }

    private func attach(_ store: ClipboardStore, listedIDs: Set<ClipItem.ID>, removedImages: Set<ClipItem.ID>) {
        self.store = store
        let logError = logError
        writer = HistoryWriter(
            store: store,
            listedIDs: listedIDs,
            removedImages: removedImages,
            reportError: { message in Task { @MainActor in logError(message) } },
            didWrite: { [weak self] in Task { @MainActor in self?.refreshUnsavedImages() } }
        )
    }

    /// The SHA-256 of an image's PNG bytes, which identifies a repeat of the same image.
    private static func digest(of png: Data) -> String {
        SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
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
