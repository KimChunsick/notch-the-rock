import Observation
import SwiftUI

/// What the Agents screen shows, and the requests waiting for an answer there.
@MainActor
@Observable
final class AgentsScreenModel {
    /// Oldest first; the screen shows the first.
    private(set) var items: [ScreenItem] = []
    /// The open sessions of every agent, listed under the requests.
    let sessions = AgentSessionList()
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<ScreenResponse, Never>] = [:]
    @ObservationIgnored private var count = 0

    /// Shows `content` until the user answers on the screen, the deadline passes or the calling task
    /// is cancelled (the hook went away); the item leaves the screen in every case.
    func show(
        title: String,
        content: ScreenItem.Content,
        accent: Color,
        allowsSession: Bool = false,
        takesDenyReason: Bool = false,
        releaseTitle: String = ClaudeBridge.releaseTitle,
        until deadline: ContinuousClock.Instant
    ) async -> ScreenResponse {
        guard !Task.isCancelled else { return .cancelled }
        count += 1
        let id = count
        let left = deadline - .now
        let expires = Date.now.addingTimeInterval(Double(left.components.seconds) + Double(left.components.attoseconds) / 1e18)
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            if !Task.isCancelled { self?.respond(to: id, with: .timedOut) }
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiting[id] = continuation
                items.append(ScreenItem(
                    id: id, title: title, content: content, expires: expires, accent: accent,
                    allowsSession: allowsSession, takesDenyReason: takesDenyReason, releaseTitle: releaseTitle
                ))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.respond(to: id, with: .cancelled) }
        }
    }

    /// Answers the item `id`; an item already answered is ignored.
    func respond(to id: Int, with response: ScreenResponse) {
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        items.removeAll { $0.id == id }
        continuation.resume(returning: response)
    }

    func cancelAll() {
        for id in waiting.keys {
            respond(to: id, with: .cancelled)
        }
    }
}
