import ApplicationServices
import NotchKit
import Observation
import OSLog

/// What the notch shows, decided by `NotchHostModel.state`.
enum NotchState: Equatable {
    case collapsed
    case expanded
    case hud
    case attention
    case takeover
}

/// The single owner of everything the notch shows. Plugins reach it through their `NotchContext`;
/// the window observes it and only draws what `state` says.
///
/// Arbitration: takeover > attention > expanded (the user is hovering or a plugin asked) > HUD >
/// collapsed. The collapsed notch carries the highest-priority unexpired live activity; on a
/// priority tie the most recently posted one wins. Time-bound items are removed by `expireDue()`,
/// which the model schedules itself for the next deadline.
@MainActor
@Observable
final class NotchHostModel: NotchHost {
    struct Tab: Identifiable {
        let pluginID: String
        let tab: PluginTab
        var id: String { pluginID }
    }

    struct PostedActivity {
        let pluginID: String
        let activity: LiveActivity
        let order: Int
        let deadline: ContinuousClock.Instant?
    }

    struct ShownHUD {
        let pluginID: String
        let hud: HUD
        let deadline: ContinuousClock.Instant
    }

    struct PendingAttention: Identifiable {
        let id: Int
        let pluginID: String
        let request: AttentionRequest
        let deadline: ContinuousClock.Instant?
        fileprivate let continuation: CheckedContinuation<AttentionResponse, Never>
    }

    struct ShownTakeover {
        let pluginID: String
        let takeover: Takeover
        let deadline: ContinuousClock.Instant
    }

    private struct ActivityKey: Hashable {
        let pluginID: String
        let id: String
    }

    private(set) var hud: ShownHUD?
    private(set) var takeover: ShownTakeover?
    private(set) var isExpanded: Bool
    private(set) var selectedTabID: String?
    /// Plugin tabs of the expanded notch, in tab bar order. Set by whoever loads the plugins.
    var tabs: [Tab] = [] {
        didSet {
            if !tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = tabs.first?.id }
        }
    }

    private var activities: [ActivityKey: PostedActivity] = [:]
    /// Waiting requests, oldest first; only the first is shown.
    private var attentions: [PendingAttention] = []
    private var postCount = 0
    private var attentionCount = 0

    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let pinnedExpansion: Bool?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "plugin")

    /// - Parameter pinnedExpansion: when set, the notch stays expanded (`true`) or collapsed
    ///   (`false`) whatever the pointer or plugins ask; used to capture a state without a mouse.
    init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }, pinnedExpansion: Bool? = nil) {
        self.now = now
        self.pinnedExpansion = pinnedExpansion
        isExpanded = pinnedExpansion ?? false
    }

    var state: NotchState {
        if takeover != nil { return .takeover }
        if !attentions.isEmpty { return .attention }
        if isExpanded { return .expanded }
        if hud != nil { return .hud }
        return .collapsed
    }

    /// The live activity shown beside the collapsed notch.
    var liveActivity: PostedActivity? {
        activities.values.max { ($0.activity.priority, $0.order) < ($1.activity.priority, $1.order) }
    }

    var attention: PendingAttention? { attentions.first }

    // MARK: Pointer and window

    func setHovering(_ hovering: Bool) {
        setExpanded(hovering)
    }

    func selectTab(_ pluginID: String) {
        if tabs.contains(where: { $0.id == pluginID }) { selectedTabID = pluginID }
    }

    /// Answers the attention request `id`. Only the first response counts; later ones (a second
    /// click, a timeout that fires after an answer, a cancellation) find nothing and do nothing.
    func respond(_ response: AttentionResponse, to id: PendingAttention.ID) {
        guard let index = attentions.firstIndex(where: { $0.id == id }) else { return }
        let pending = attentions.remove(at: index)
        pending.continuation.resume(returning: response)
        scheduleExpiry()
    }

    /// Removes every item whose time is up and answers timed-out requests with `.timedOut`.
    func expireDue() {
        let current = now()
        for (key, posted) in activities where posted.deadline.map({ $0 <= current }) ?? false {
            activities[key] = nil
        }
        if let hud, hud.deadline <= current { self.hud = nil }
        if let takeover, takeover.deadline <= current { self.takeover = nil }
        for pending in attentions where pending.deadline.map({ $0 <= current }) ?? false {
            respond(.timedOut, to: pending.id)
        }
        scheduleExpiry()
    }

    private func setExpanded(_ expanded: Bool) {
        guard pinnedExpansion == nil else { return }
        isExpanded = expanded
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        let deadlines = activities.values.compactMap(\.deadline)
            + attentions.compactMap(\.deadline)
            + [hud?.deadline, takeover?.deadline].compactMap { $0 }
        guard let next = deadlines.min() else {
            expiryTask = nil
            return
        }
        expiryTask = Task { [weak self] in
            try? await Task.sleep(until: next, clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.expireDue()
        }
    }

    // MARK: NotchHost

    func post(_ activity: LiveActivity, from pluginID: String) {
        postCount += 1
        activities[ActivityKey(pluginID: pluginID, id: activity.id)] = PostedActivity(
            pluginID: pluginID,
            activity: activity,
            order: postCount,
            deadline: activity.expiresAfter.map { now() + $0 }
        )
        scheduleExpiry()
    }

    func clearActivity(id: String, from pluginID: String) {
        activities[ActivityKey(pluginID: pluginID, id: id)] = nil
        scheduleExpiry()
    }

    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {
        self.hud = ShownHUD(pluginID: pluginID, hud: hud, deadline: now() + duration)
        scheduleExpiry()
    }

    /// A takeover ends in the collapsed notch, so it also ends a hover or plugin expansion.
    func present(_ takeover: Takeover, from pluginID: String) {
        self.takeover = ShownTakeover(pluginID: pluginID, takeover: takeover, deadline: now() + takeover.duration)
        setExpanded(false)
        scheduleExpiry()
    }

    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse {
        if Task.isCancelled { return .cancelled }
        attentionCount += 1
        let id = attentionCount
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attentions.append(PendingAttention(
                    id: id,
                    pluginID: pluginID,
                    request: request,
                    deadline: request.timeout.map { now() + $0 },
                    continuation: continuation
                ))
                scheduleExpiry()
            }
        } onCancel: {
            Task { @MainActor in self.respond(.cancelled, to: id) }
        }
    }

    func expand(toTabOf pluginID: String) {
        selectTab(pluginID)
        setExpanded(true)
    }

    func collapse(from pluginID: String) {
        setExpanded(false)
    }

    var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    func requestAccessibility(from pluginID: String) {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func log(_ level: LogLevel, _ message: String, from pluginID: String) {
        let type: OSLogType = switch level {
        case .debug: .debug
        case .info: .info
        case .error: .error
        @unknown default: .default
        }
        logger.log(level: type, "\(pluginID, privacy: .public): \(message, privacy: .public)")
    }
}
