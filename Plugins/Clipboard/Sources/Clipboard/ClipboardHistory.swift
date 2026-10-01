import AppKit
import CryptoKit
import Observation

/// The clipboard history, newest first, shared by the plugin, its tab and its settings page.
///
/// Rules: an identical repeat moves the existing entry to the top; pinned entries stay until they
/// are deleted; at most `unpinnedLimit` unpinned entries are kept and the oldest go first. Every
/// change is handed to a `HistoryWriter`, which writes the list in the background.
///
/// An entry is saved once its image file, if it has one, and a list on disk that names it are both
/// written; the image file always comes first. Until then the entry lives in memory only, image
/// original included, and `open(_:)` drops it: turning the plugin off and on, or quitting, loses
/// it. Without a writable store (no key, or a store that cannot be read) every entry lives in
/// memory only.
@MainActor
@Observable
final class ClipboardHistory {
    static let unpinnedLimit = 200
    /// How long `unsavedCount` stays above zero before the tab mentions it, so a list that is
    /// written a moment after a copy shows no notice.
    static let unsavedNoticeDelay: TimeInterval = 2

    private(set) var items: [ClipItem] = []
    /// How many entries are not saved: every entry without a writable store; with one, each entry
    /// the list last written does not name, whether its list is queued, being written or could
    /// not be written. An image without a file is never in a list, so it counts too.
    private(set) var unsavedCount = 0
    /// When `unsavedCount` last rose above zero; nil while it is zero.
    private(set) var unsavedSince: Date?
    /// A stored list that could not be read. It is left untouched, and nothing is written, until
    /// `resetUnreadableStore()`.
    private var unreadableStore: ClipboardStore?
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private var writer: HistoryWriter?
    /// The PNG of each image entry without an image file: every image while there is no writable
    /// store, and with one, each image whose file could not be written. The lists handed to the
    /// writer leave these entries out. Dropped with its entry.
    @ObservationIgnored private var originals: [ClipItem.ID: Data] = [:]
    @ObservationIgnored private let logError: @MainActor (String) -> Void
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let sources: SourceAppLookup

    /// `now` gives the time `unsavedSince` records; tests pass a clock they move themselves.
    /// `sources` finds the app a pasteboard change came from.
    init(
        logError: @escaping @MainActor (String) -> Void,
        now: @escaping @MainActor () -> Date = { .now },
        sources: SourceAppLookup = .system
    ) {
        self.logError = logError
        self.now = now
        self.sources = sources
    }

    /// Whether the tab mentions the unsaved entries at `date`: `unsavedCount` has stayed above zero
    /// for `unsavedNoticeDelay`.
    func showsUnsavedNotice(at date: Date) -> Bool {
        guard let unsavedSince else { return false }
        return date >= unsavedSince + Self.unsavedNoticeDelay
    }

    /// Whether the stored history could not be read, so this session is kept in memory only.
    var isStoreUnreadable: Bool { unreadableStore != nil }

    /// Replaces the history with what `store` holds and saves every later change there; entries
    /// that were not saved are dropped. Image files the stored list does not name were never saved,
    /// or belong to removed entries, and are deleted. A list that cannot be read, or a directory
    /// that cannot be listed, leaves the history empty and in memory, and the store untouched. With
    /// nil the history starts empty and keeps its entries in memory only.
    func open(_ store: ClipboardStore?) {
        flush()
        self.store = nil
        writer = nil
        unreadableStore = nil
        originals = [:]
        items = []
        defer { refreshUnsavedCount() }
        guard let store else { return }
        do {
            items = try store.loadList()
        } catch {
            unreadableStore = store
            logError("could not read the clipboard history, keeping it untouched and this session in memory: \(error)")
            return
        }
        let listedIDs = Set(items.map(\.id))
        do {
            try store.deleteImages(except: listedIDs)
        } catch {
            logError("could not delete clipboard images that were never saved: \(error)")
        }
        attach(store, listedIDs: listedIDs)
    }

    /// Deletes the unreadable stored history, image files first and the list last, and saves the
    /// entries of this session in its place; an image whose file cannot be written stays in memory
    /// only. When a deletion fails the list is still there, so the store stays unreadable.
    func resetUnreadableStore() {
        guard let store = unreadableStore else { return }
        do {
            try store.deleteAll()
        } catch {
            logError("could not delete the unreadable clipboard history: \(error)")
            return
        }
        unreadableStore = nil
        attach(store, listedIDs: [])
        for (id, png) in originals where writeImageFile(png, for: id) {
            originals[id] = nil
        }
        save()
    }

    /// Returns once every change so far has been tried on disk, writing again a list whose write
    /// failed.
    func flush() {
        writer?.flush()
        refreshUnsavedCount()
    }

    /// Records the pasteboard's current content, with the app it came from, unless it is excluded
    /// or empty.
    func record(from pasteboard: NSPasteboard) {
        if let capture = ClipCapture.read(from: pasteboard) {
            record(capture, source: sources.source(of: pasteboard))
        }
    }

    /// A repeat keeps the app it was copied from before when `source` is nil, so copying an entry
    /// back from this app does not lose it.
    func record(_ capture: ClipCapture, at date: Date = .now, source: SourceApp? = nil) {
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
            if let source { item.source = source }
            items.insert(item, at: 0)
            save()
            return
        }

        let item = ClipItem(id: UUID(), content: content, date: date, isPinned: false, source: source)
        // One file per image, written here before any list that names it.
        if let png, !writeImageFile(png, for: item.id) {
            originals[item.id] = png
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

    /// Writes the image file of the entry `id`. False without a writable store or when the write
    /// fails; the entry is then kept in memory only.
    private func writeImageFile(_ png: Data, for id: ClipItem.ID) -> Bool {
        guard let store else { return false }
        do {
            try store.saveImage(png, for: id)
            return true
        } catch {
            logError("could not save a copied image, keeping it in memory only: \(error)")
            return false
        }
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

    /// Removes matching entries and saves the list. Their image files are deleted once that list
    /// is written; an interruption leaves at worst an image file the list on disk does not name,
    /// which the next `open(_:)` deletes.
    private func remove(where shouldRemove: (ClipItem) -> Bool) {
        let removed = items.filter(shouldRemove)
        guard !removed.isEmpty else { return }
        items.removeAll(where: shouldRemove)
        let removedImages = Set(removed.filter { $0.kind == .image }.map(\.id))
        for id in removedImages {
            originals[id] = nil
        }
        save(deletingImagesOf: removedImages)
    }

    /// Queues the list for writing. It leaves out the images without a file, so a list on disk
    /// names only images whose file is written.
    private func save(deletingImagesOf removedImages: Set<ClipItem.ID> = []) {
        writer?.save(items.filter { originals[$0.id] == nil }, deletingImagesOf: removedImages)
        refreshUnsavedCount()
    }

    private func refreshUnsavedCount() {
        var count = items.count
        if let writer {
            let listedIDs = writer.listedIDs
            count = items.count { !listedIDs.contains($0.id) }
        }
        guard count != unsavedCount else { return }
        if count == 0 {
            unsavedSince = nil
        } else if unsavedCount == 0 {
            unsavedSince = now()
        }
        unsavedCount = count
    }

    private func attach(_ store: ClipboardStore, listedIDs: Set<ClipItem.ID>) {
        self.store = store
        let logError = logError
        writer = HistoryWriter(
            store: store,
            listedIDs: listedIDs,
            reportError: { message in Task { @MainActor in logError(message) } },
            didTryWrite: { [weak self] in Task { @MainActor in self?.refreshUnsavedCount() } }
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
