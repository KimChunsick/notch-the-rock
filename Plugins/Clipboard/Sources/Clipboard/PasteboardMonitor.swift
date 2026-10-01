import AppKit

/// Polls a pasteboard's `changeCount` and reports every change until `stop()`. macOS sends no
/// notification for pasteboard changes, so polling is the only way to see a `pbcopy`.
@MainActor
final class PasteboardMonitor {
    /// Short enough that a copy shows up in the list well within a second.
    static let interval: Duration = .milliseconds(300)

    private let pasteboard: NSPasteboard
    private let onChange: @MainActor (NSPasteboard) -> Void
    private var lastChangeCount = 0
    private var task: Task<Void, Never>?

    init(pasteboard: NSPasteboard, onChange: @escaping @MainActor (NSPasteboard) -> Void) {
        self.pasteboard = pasteboard
        self.onChange = onChange
    }

    /// Starts polling. What the pasteboard holds now is not reported, only later changes.
    func start() {
        guard task == nil else { return }
        lastChangeCount = pasteboard.changeCount
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                guard let self, !Task.isCancelled else { return }
                self.poll()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        onChange(pasteboard)
    }
}
