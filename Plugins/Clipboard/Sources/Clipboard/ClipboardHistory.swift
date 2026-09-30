import AppKit
import CryptoKit
import Observation

/// The clipboard history, newest first, shared by the plugin, its tab and its settings page.
///
/// Rules: an identical repeat moves the existing entry to the top; pinned entries stay until they
/// are deleted; at most `unpinnedLimit` unpinned entries are kept and the oldest go first. Every
/// change is written to the store at once. Without a store (no key) the history lives in memory.
@MainActor
@Observable
final class ClipboardHistory {
    static let unpinnedLimit = 200

    private(set) var items: [ClipItem] = []
    @ObservationIgnored private var store: ClipboardStore?
    @ObservationIgnored private let logError: @MainActor (String) -> Void

    init(logError: @escaping @MainActor (String) -> Void) {
        self.logError = logError
    }

    /// Replaces the list with what `store` holds and saves every later change there. An unreadable
    /// list starts empty and is replaced by the next save. With nil the history keeps its entries
    /// in memory only.
    func open(_ store: ClipboardStore?) {
        self.store = store
        guard let store else { return }
        do {
            items = try store.loadItems()
        } catch {
            items = []
            logError("could not read the clipboard history, starting empty: \(error)")
            return
        }
        do {
            try store.deleteImages(notIn: Set(items.map(\.id)))
        } catch {
            logError("could not remove unused clipboard images: \(error)")
        }
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
        if let png, let store {
            do {
                try store.saveImage(png, for: item.id)
            } catch {
                logError("could not save a copied image: \(error)")
                return
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
        guard let store else {
            logError("the image of a clipboard entry is not available without a history key")
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

    /// Removes matching entries, saves the list, then deletes their image files. In that order an
    /// interruption leaves at worst an unused image file, which the next `open(_:)` removes.
    private func remove(where shouldRemove: (ClipItem) -> Bool) {
        let removed = items.filter(shouldRemove)
        guard !removed.isEmpty else { return }
        items.removeAll(where: shouldRemove)
        save()
        guard let store else { return }
        for item in removed where item.kind == .image {
            do {
                try store.deleteImage(for: item.id)
            } catch {
                logError("could not delete a clipboard image: \(error)")
            }
        }
    }

    private func save() {
        guard let store else { return }
        do {
            try store.saveItems(items)
        } catch {
            logError("could not save the clipboard history: \(error)")
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
