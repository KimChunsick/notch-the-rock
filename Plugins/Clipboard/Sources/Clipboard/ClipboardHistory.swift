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
/// original included, and `open(_:)` keeps it and saves it in the store it opens; only quitting
/// loses it. Without a writable store (no key yet, none, or a store that cannot be read) every entry
/// lives in memory only. Every copy shows in the list as soon as it is recorded, whatever the store.
///
/// A deletion, clearing or pin change made before a list is read, while a store is being opened or
/// without a readable store, is kept and applied to the next list read: what the user deleted then
/// does not come back from disk, and a pin set or cleared then holds.
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
    /// Whether a store is being opened: set by `beginOpening()`, cleared by `open(_:)`.
    @ObservationIgnored private var isOpening = false
    /// Whether `resetUnreadableStore()` is running.
    @ObservationIgnored private var isResetting = false
    /// The entries copied while a store was being opened. One may have been written to the store
    /// opened before, which need not be the next one, so `open(_:)` keeps them whatever it finds.
    @ObservationIgnored private var copiedWhileOpening: Set<ClipItem.ID> = []
    /// The user's deletions, clearings and pin changes, in order, that the next list read may not
    /// have: made while a store was being opened, or while there was no readable store. Applied by
    /// the next `open(_:)` that reads a list; a reset of an unreadable store drops them.
    @ObservationIgnored private var edits: [Edit] = []

    /// A change the user made to the entries with some content, or to every unpinned entry.
    private enum Edit {
        case delete(ClipItem.Content)
        case setPinned(Bool, ClipItem.Content)
        case clearUnpinned
    }

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

    /// Replaces the history with what `store` holds and saves every later change there, keeping the
    /// entries this session still owes: every entry that no list on disk names and every entry
    /// copied since `beginOpening()`. The user's edits not saved there come first: the stored
    /// entries they deleted or cleared go, and the pins they set or cleared hold. Then each owed
    /// entry goes back where its date puts it, newest first; one whose content is stored already
    /// merges into that entry (see `merge(_:png:)`). Then the oldest unpinned entries beyond the
    /// limit go, and the list is saved. Image files the stored list does not name were never saved,
    /// or belong to removed entries, and are deleted. A list that cannot be read, or a directory that
    /// cannot be listed, leaves the store untouched and the owed entries in memory until
    /// `resetUnreadableStore()`. With nil only the owed entries remain, in memory, for the next
    /// opening. Without a list read, the edits wait for the next opening that reads one.
    func open(_ store: ClipboardStore?) {
        let owed = takeOwedEntries()
        replaceContents(with: store)
        let appliesEdits = writer != nil && !edits.isEmpty
        let removedImages = appliesEdits ? applyEdits(sparing: Set(owed.map(\.item.id))) : []
        guard !owed.isEmpty || appliesEdits else {
            refreshUnsavedCount()
            return
        }
        for entry in owed {
            merge(entry.item, png: entry.png)
        }
        dropUnpinnedOverLimit(deletingImagesOf: removedImages)
    }

    /// Applies the edits to the list just read, in order and by content, and forgets them. The owed
    /// entries are left alone: they carry every edit already, and may be newer than it (copied again
    /// after a deletion). Returns the removed images, whose files go once a list without them is
    /// written.
    private func applyEdits(sparing owed: Set<ClipItem.ID>) -> Set<ClipItem.ID> {
        var removedImages: Set<ClipItem.ID> = []
        for edit in edits {
            switch edit {
            case .delete(let content):
                removedImages.formUnion(removeEntries { !owed.contains($0.id) && $0.content.isSameClip(as: content) })
            case .clearUnpinned:
                removedImages.formUnion(removeEntries { !owed.contains($0.id) && !$0.isPinned })
            case .setPinned(let pinned, let content):
                for index in items.indices where !owed.contains(items[index].id) && items[index].content.isSameClip(as: content) {
                    items[index].isPinned = pinned
                }
            }
        }
        edits = []
        return removedImages
    }

    /// Call when a store starts opening: the copies recorded until the next `open(_:)` are kept by
    /// it whatever that store holds. An opening that never finishes keeps them for the next one.
    func beginOpening() {
        isOpening = true
    }

    /// The entries the next store must keep, oldest first, each image with its PNG: from memory, or
    /// read from the current store before the next one deletes the files its list does not name. An
    /// image that cannot be read is reported and left out.
    private func takeOwedEntries() -> [(item: ClipItem, png: Data?)] {
        flush()
        let listedIDs = writer?.listedIDs ?? []
        let copied = copiedWhileOpening
        copiedWhileOpening = []
        isOpening = false
        return items.reversed().compactMap { item in
            guard !listedIDs.contains(item.id) || copied.contains(item.id) else { return nil }
            guard item.kind == .image else { return (item, nil) }
            guard let png = imageData(for: item) else { return nil }
            return (item, png)
        }
    }

    /// Puts an owed entry back before the first entry that is not newer. A stored entry with the
    /// same content stays instead, with the later date and the owed entry's source when it has one;
    /// the same entry takes the owed pin, which is newer, and another keeps a pin of either. An owed
    /// image's PNG is written first, under the id that stays, unless the stored file already holds
    /// it: a stored file that is missing or damaged is repaired. A PNG that cannot be written stays
    /// in memory.
    private func merge(_ owed: ClipItem, png: Data?) {
        var entry = owed
        var storedPNG: Data?
        if let index = items.firstIndex(where: { $0.content.isSameClip(as: owed.content) }) {
            entry = items.remove(at: index)
            entry.date = max(entry.date, owed.date)
            if let source = owed.source { entry.source = source }
            entry.isPinned = entry.id == owed.id ? owed.isPinned : entry.isPinned || owed.isPinned
            if png != nil { storedPNG = try? store?.imageData(for: entry.id) }
        }
        if let png, storedPNG != png, !writeImageFile(png, for: entry.id) {
            originals[entry.id] = png
        }
        items.insert(entry, at: items.firstIndex { $0.date <= entry.date } ?? items.endIndex)
    }

    private func replaceContents(with store: ClipboardStore?) {
        self.store = nil
        writer = nil
        unreadableStore = nil
        originals = [:]
        items = []
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
    /// only. The store decides again under the opening lock, with the key in the key file
    /// (`ClipboardStore.resetIfUnreadable()`): a history that can be read by then, saved by another
    /// opening or reachable again, is not deleted but opened as `open(_:)` opens one, with this
    /// session's entries and edits kept. That runs off the main actor, on the queue openings use,
    /// so the main actor never waits for the lock; until it is done, copies, deletions and pin
    /// changes are kept as while a store is being opened, and the store found is opened with
    /// `open(_:)`. One reset runs at a time: a call while one runs does nothing. When the key file
    /// cannot be read or created, the lock cannot be taken in time or a deletion fails, the list is
    /// still there, so the store stays unreadable and the session in memory.
    func resetUnreadableStore() async {
        guard let unreadable = unreadableStore, !isResetting else { return }
        isResetting = true
        defer { isResetting = false }
        beginOpening()
        switch await ClipboardStore.onKeyQueue({ try unreadable.resetIfUnreadable() }) {
        case .success(.readable(let store)):
            open(store)
        case .success(.deleted(let store)):
            // The history the edits were kept for is gone; the entries saved in its place carry them.
            edits = []
            open(store)
        case .failure(let error):
            // The copies made meanwhile stay owed to the next opening, which ends the opening begun here.
            logError("could not delete the unreadable clipboard history: \(error)")
        }
    }

    /// Returns once every change so far has been tried on disk, writing again a list whose write
    /// failed.
    func flush() {
        writer?.flush()
        refreshUnsavedCount()
    }

    /// Records the pasteboard's current content, with the app it came from, unless it is excluded
    /// or empty. While a store is being opened, the next `open(_:)` keeps it.
    func record(from pasteboard: NSPasteboard) {
        guard let capture = ClipCapture.read(from: pasteboard) else { return }
        let id = record(capture, source: sources.source(of: pasteboard))
        if isOpening {
            copiedWhileOpening.insert(id)
        }
    }

    /// Returns the id of the entry that holds the copy, at the top. A repeat keeps the app it was
    /// copied from before when `source` is nil, so copying an entry back from this app does not lose
    /// it.
    @discardableResult
    func record(_ capture: ClipCapture, at date: Date = .now, source: SourceApp? = nil) -> ClipItem.ID {
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
            return item.id
        }

        let item = ClipItem(id: UUID(), content: content, date: date, isPinned: false, source: source)
        // One file per image, written here before any list that names it.
        if let png, !writeImageFile(png, for: item.id) {
            originals[item.id] = png
        }
        items.insert(item, at: 0)
        dropUnpinnedOverLimit()
        return item.id
    }

    func setPinned(_ pinned: Bool, for id: ClipItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].isPinned != pinned else { return }
        items[index].isPinned = pinned
        note(.setPinned(pinned, items[index].content))
        if pinned {
            save()
        } else {
            dropUnpinnedOverLimit()
        }
    }

    func delete(_ id: ClipItem.ID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        note(.delete(item.content))
        remove { $0.id == id }
    }

    /// Deletes every entry that is not pinned.
    func clearUnpinned() {
        note(.clearUnpinned)
        remove { !$0.isPinned }
    }

    /// Keeps `edit` for the next list `open(_:)` reads when that list may not have it: while a store
    /// is being opened (the list read may be another store's, or written before this edit), or
    /// while there is no readable store to save it in.
    private func note(_ edit: Edit) {
        guard isOpening || writer == nil else { return }
        edits.append(edit)
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

    /// Drops the oldest unpinned entries beyond the limit and saves the list; the image files of
    /// `removedImages`, entries removed before, go with theirs once it is written.
    private func dropUnpinnedOverLimit(deletingImagesOf removedImages: Set<ClipItem.ID> = []) {
        var removedImages = removedImages
        var unpinned = items.filter { !$0.isPinned }.count
        if unpinned > Self.unpinnedLimit {
            // `items` is newest first, so the unpinned entries past the limit are the oldest.
            var dropped: Set<ClipItem.ID> = []
            for item in items.reversed() where !item.isPinned && unpinned > Self.unpinnedLimit {
                dropped.insert(item.id)
                unpinned -= 1
            }
            removedImages.formUnion(removeEntries { dropped.contains($0.id) })
        }
        save(deletingImagesOf: removedImages)
    }

    /// Removes matching entries and saves the list. Their image files are deleted once that list
    /// is written; an interruption leaves at worst an image file the list on disk does not name,
    /// which the next `open(_:)` deletes.
    private func remove(where shouldRemove: (ClipItem) -> Bool) {
        guard items.contains(where: shouldRemove) else { return }
        save(deletingImagesOf: removeEntries(where: shouldRemove))
    }

    /// Removes matching entries with their originals and returns the removed images, whose files
    /// must go only once a list without them is written.
    private func removeEntries(where shouldRemove: (ClipItem) -> Bool) -> Set<ClipItem.ID> {
        let removedImages = Set(items.filter { shouldRemove($0) && $0.kind == .image }.map(\.id))
        items.removeAll(where: shouldRemove)
        for id in removedImages {
            originals[id] = nil
        }
        return removedImages
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
