import Foundation
import os

/// Writes the history list to its store on a background serial queue, so a change on the main
/// actor never waits for encoding, encryption or the disk.
///
/// A list queued while an earlier one is still waiting replaces it: only the latest is written.
/// Image files of removed entries are deleted only after a list that no longer refers to them has
/// been written. When that write fails they stay, and `ClipboardHistory.open(_:)` later removes the
/// ones the list on disk does not refer to.
final class HistoryWriter: Sendable {
    private struct Pending: Sendable {
        var items: [ClipItem]?
        var imagesToDelete: Set<UUID> = []
    }

    private let store: ClipboardStore
    private let reportError: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "com.notchtherock.clipboard.history-writer")
    private let pending = OSAllocatedUnfairLock(initialState: Pending())

    /// `reportError` is called on the writer's queue.
    init(store: ClipboardStore, reportError: @escaping @Sendable (String) -> Void) {
        self.store = store
        self.reportError = reportError
    }

    /// Queues `items` as the list to write and `removedImages` as image files to delete once a
    /// list without them is written.
    func save(_ items: [ClipItem], deletingImagesOf removedImages: Set<UUID> = []) {
        let isQueued = pending.withLock { pending in
            let isQueued = pending.items != nil
            pending.items = items
            pending.imagesToDelete.formUnion(removedImages)
            return isQueued
        }
        if !isQueued {
            queue.async { self.writePending() }
        }
    }

    /// Returns once everything queued so far is written.
    func flush() {
        queue.sync {}
    }

    private func writePending() {
        let work = pending.withLock { pending in
            defer { pending = Pending() }
            return pending
        }
        guard let items = work.items else { return }
        do {
            try store.saveItems(items)
        } catch {
            reportError("could not save the clipboard history, keeping the images of removed entries: \(error)")
            return
        }
        for id in work.imagesToDelete {
            do {
                try store.deleteImage(for: id)
            } catch {
                reportError("could not delete a clipboard image: \(error)")
            }
        }
    }
}
