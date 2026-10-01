import Foundation
import os

/// Writes the history list to its store on a background serial queue, so a change on the main
/// actor never waits for encoding, encryption or the disk.
///
/// A list queued while an earlier one is still waiting replaces it: only the latest is written. A
/// list whose write fails is kept and written again by the next `save` (its newer list wins) or
/// `flush()`; the writer never retries on its own.
///
/// The image files of removed entries are deleted once a list without them is written, so a list
/// on disk never names an image file that is gone. A file left behind, because no such list was
/// written or its deletion failed, is not named by the list on disk, and the next
/// `ClipboardHistory.open(_:)` deletes it.
final class HistoryWriter: Sendable {
    private struct State: Sendable {
        /// The latest list not on disk yet: queued, or kept after a failed write.
        var items: [ClipItem]?
        /// Whether `writePending()` is queued.
        var isScheduled = false
        /// Image files of removed entries to delete once a list without them is written.
        var removedImages: Set<UUID> = []
        /// The entry ids of the list on disk.
        var listedIDs: Set<UUID>
        /// Whether the last list tried could not be written. It stays set until a list is written.
        var lastWriteFailed = false
    }

    private let store: ClipboardStore
    private let reportError: @Sendable (String) -> Void
    private let didTryWrite: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.notchtherock.clipboard.history-writer")
    private let state: OSAllocatedUnfairLock<State>

    /// `listedIDs` are the entries of the list on disk. `reportError`, and `didTryWrite` after every
    /// list write that succeeded or failed, are called on the writer's queue.
    init(
        store: ClipboardStore,
        listedIDs: Set<UUID>,
        reportError: @escaping @Sendable (String) -> Void,
        didTryWrite: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.reportError = reportError
        self.didTryWrite = didTryWrite
        state = OSAllocatedUnfairLock(initialState: State(listedIDs: listedIDs))
    }

    /// Queues `items` as the list to write and `removedImages` as image files to delete once a list
    /// without them is written.
    func save(_ items: [ClipItem], deletingImagesOf removedImages: Set<UUID> = []) {
        state.withLock { state in
            state.items = items
            state.removedImages.formUnion(removedImages)
        }
        scheduleWrite()
    }

    /// Returns once everything queued so far has been tried, and a list kept after a failed write,
    /// including one that was being written when `flush()` was called, has been tried again.
    func flush() {
        queue.sync {}
        scheduleWrite()
        queue.sync {}
    }

    /// The entry ids of the list on disk while the last list tried could not be written; nil when
    /// it was written, or none was tried yet.
    var listedIDsAfterFailure: Set<UUID>? {
        state.withLock { $0.lastWriteFailed ? $0.listedIDs : nil }
    }

    private func scheduleWrite() {
        let needsWrite = state.withLock { state in
            guard state.items != nil, !state.isScheduled else { return false }
            state.isScheduled = true
            return true
        }
        if needsWrite {
            queue.async { self.writePending() }
        }
    }

    private func writePending() {
        let work = state.withLock { state -> (items: [ClipItem], removed: Set<UUID>)? in
            state.isScheduled = false
            guard let items = state.items else { return nil }
            state.items = nil
            return (items, state.removedImages)
        }
        guard let work else { return }
        do {
            try store.saveList(work.items)
        } catch {
            // A newer list queued meanwhile replaces this one; otherwise this one is kept.
            state.withLock { state in
                if state.items == nil { state.items = work.items }
                state.lastWriteFailed = true
            }
            reportError("could not save the clipboard history, keeping it to write again: \(error)")
            didTryWrite()
            return
        }
        // `work.items` was the latest list when `work.removed` was taken, and a removed entry never
        // comes back, so the list just written names none of them.
        state.withLock { state in
            state.listedIDs = Set(work.items.map(\.id))
            state.lastWriteFailed = false
            state.removedImages.subtract(work.removed)
        }
        didTryWrite()
        for id in work.removed {
            do {
                try store.deleteImage(for: id)
            } catch {
                reportError("could not delete a clipboard image: \(error)")
            }
        }
    }
}
