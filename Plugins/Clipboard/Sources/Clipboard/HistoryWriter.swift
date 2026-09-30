import Foundation
import os

/// Writes the history list to its store on a background serial queue, so a change on the main
/// actor never waits for encoding, encryption or the disk.
///
/// A list queued while an earlier one is still waiting replaces it: only the latest is written. A
/// list whose write fails is kept and written again by the next `save` (its newer list wins) or
/// `flush()`; the writer never retries on its own.
///
/// The image file of a removed entry is deleted as soon as no list on disk names the entry: at
/// once when the list on disk never named it, otherwise after a list without it is written. Until
/// its file is gone, every list written names it in `removedImageIDs`, so that an interrupted
/// deletion is finished by the next `ClipboardHistory.open(_:)` and the image is never brought back.
final class HistoryWriter: Sendable {
    private struct State: Sendable {
        /// The latest list not on disk yet: queued, or kept after a failed write.
        var items: [ClipItem]?
        /// Whether `writePending()` is queued.
        var isScheduled = false
        /// Images of removed entries whose file is not deleted yet.
        var removedImages: Set<UUID>
        /// The entry ids of the list on disk.
        var listedIDs: Set<UUID>
    }

    private let store: ClipboardStore
    private let reportError: @Sendable (String) -> Void
    private let didWrite: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.notchtherock.clipboard.history-writer")
    private let state: OSAllocatedUnfairLock<State>

    /// `listedIDs` are the entries of the list on disk and `removedImages` the removed entries'
    /// image files still to delete. `reportError`, and `didWrite` after every list written, are
    /// called on the writer's queue.
    init(
        store: ClipboardStore,
        listedIDs: Set<UUID>,
        removedImages: Set<UUID>,
        reportError: @escaping @Sendable (String) -> Void,
        didWrite: @escaping @Sendable () -> Void
    ) {
        self.store = store
        self.reportError = reportError
        self.didWrite = didWrite
        state = OSAllocatedUnfairLock(initialState: State(removedImages: removedImages, listedIDs: listedIDs))
    }

    /// Queues `items` as the list to write and `removedImages` as image files to delete once no
    /// list on disk names them.
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

    /// The entry ids of the list on disk: the one there when the writer was made, then the last
    /// one written.
    var writtenIDs: Set<UUID> {
        state.withLock { $0.listedIDs }
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
        let work = state.withLock { state -> (items: [ClipItem], removed: Set<UUID>, listed: Set<UUID>)? in
            state.isScheduled = false
            guard let items = state.items else { return nil }
            state.items = nil
            return (items, state.removedImages, state.listedIDs)
        }
        guard let work else { return }
        // `work.items` is the latest list and a removed entry never comes back, so it names none
        // of `work.removed`.
        deleteImages(work.removed.subtracting(work.listed))
        let removed = state.withLock { $0.removedImages }.intersection(work.removed)
        do {
            try store.saveList(StoredList(items: work.items, removedImageIDs: removed))
        } catch {
            // A newer list queued meanwhile replaces this one; otherwise this one is kept.
            state.withLock { state in
                if state.items == nil { state.items = work.items }
            }
            reportError("could not save the clipboard history, keeping it to write again: \(error)")
            return
        }
        state.withLock { $0.listedIDs = Set(work.items.map(\.id)) }
        didWrite()
        deleteImages(removed)
    }

    private func deleteImages(_ ids: Set<UUID>) {
        for id in ids {
            do {
                try store.deleteImage(for: id)
                state.withLock { _ = $0.removedImages.remove(id) }
            } catch {
                reportError("could not delete a clipboard image: \(error)")
            }
        }
    }
}
