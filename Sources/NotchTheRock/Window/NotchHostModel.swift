import ApplicationServices
import NotchKit
import Observation
import OSLog

/// Which screen the expanded notch shows: the home, or one plugin's screen (its tab).
enum HomeScreen: Equatable {
    case home
    case detail(pluginID: String)
}

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
///
/// The expanded notch shows the home (`screen`): plugin tiles and a strip of icons, see `HomeModel`. API for
/// the keyboard and URL plans (P17, P18): `showHome()`, `open(pluginID:)`, `back()`, `escape()` and
/// the read-only `homeEntries`.
///
/// A notch opened by `showHome()` or `open(pluginID:)` while the pointer is elsewhere (the hotkey, a
/// link, a plugin) is held open: the pointer moving elsewhere does not close it, only Esc, a click
/// outside, or the pointer entering and then leaving it. Keyboard state (focus ring, quick search)
/// is in `keyboard`, see `handleKey(_:)`.
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
    /// The screen of the expanded notch. Collapsing returns it to the home.
    private(set) var screen: HomeScreen = .home
    let home: HomeModel
    let keyboard = HomeKeyboard()
    /// Opened by `showHome()` or `open(pluginID:)` while the pointer was not on the notch, and the
    /// pointer has not entered it since.
    private(set) var isHeldOpen = false
    @ObservationIgnored private var isHovering = false

    /// The running plugins in load order, as the home shows them. Set by whoever loads the plugins.
    var plugins: [HomePlugin] {
        get { home.plugins }
        set {
            home.plugins = newValue
            if case .detail(let pluginID) = screen, home.plugin(pluginID) == nil { screen = .home }
        }
    }

    /// The plugin tabs, in load order. `PluginCatalog` still hands over tabs only, so setting them
    /// makes tab-only plugins named by their tab title: strip icons without tiles. Once the catalog
    /// sets `plugins` with each plugin's tile and manifest name and symbol, this goes away.
    var tabs: [Tab] {
        get { plugins.compactMap { plugin in plugin.tab.map { Tab(pluginID: plugin.pluginID, tab: $0) } } }
        set {
            plugins = newValue.map { HomePlugin(pluginID: $0.pluginID, name: $0.tab.title, symbol: $0.tab.symbol, tab: $0.tab, tile: nil) }
        }
    }

    /// The home in the order it is shown, grid tiles then strip icons, with each plugin's name.
    var homeEntries: [HomeEntry] { home.entries }

    private var activities: [ActivityKey: PostedActivity] = [:]
    /// Waiting requests, oldest first; only the first is shown.
    private var attentions: [PendingAttention] = []
    private var postCount = 0
    private var attentionCount = 0

    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let pinnedExpansion: Bool?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "plugin")

    /// - Parameters:
    ///   - pinnedExpansion: when set, the notch stays expanded (`true`) or collapsed (`false`)
    ///     whatever the pointer or plugins ask; used to capture a state without a mouse.
    ///   - homeStore: where the home layout is saved; the app's own defaults by default.
    init(
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        pinnedExpansion: Bool? = nil,
        homeStore: HomeLayoutStore = HomeLayoutStore(defaults: .standard)
    ) {
        self.now = now
        self.pinnedExpansion = pinnedExpansion
        isExpanded = pinnedExpansion ?? false
        home = HomeModel(store: homeStore)
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

    /// Hovering starts or ends. Ending collapses the notch however it was opened; the window reports
    /// a pointer leaving through `pointerLeft()`, which keeps a held notch open.
    func setHovering(_ hovering: Bool) {
        isHovering = hovering
        if hovering { isHeldOpen = false }
        setExpanded(hovering)
    }

    /// The pointer left the notch after hovering it. A held notch stays open: the pointer has not
    /// been in it since it opened, so this leave is left over from before.
    func pointerLeft() {
        guard !isHeldOpen else { return }
        setHovering(false)
    }

    /// A click outside the notch ends a held notch. A hovered one is left to the pointer leaving.
    func clickedOutside() {
        guard isHeldOpen else { return }
        setExpanded(false)
    }

    /// The global hotkey: collapses the expanded notch, or opens the home with the focus ring on its
    /// first entry. While a takeover or an attention request shows, it does nothing.
    func toggleFromKeyboard() {
        switch state {
        case .expanded:
            setExpanded(false)
        case .collapsed, .hud:
            showHome()
            keyboard.focus = homeEntries.first?.pluginID
        case .attention, .takeover:
            break
        }
    }

    // MARK: Home navigation

    /// Expands the notch on the home.
    func showHome() {
        screen = .home
        keyboard.query = nil
        setExpanded(true)
        holdUnlessHovered()
    }

    /// Expands the notch on the plugin's screen: its own tab, or the host's fallback screen
    /// (`DefaultScreen`) for a plugin without one. A plugin that is not running opens the home instead.
    func open(pluginID: String) {
        screen = home.plugin(pluginID) == nil ? .home : .detail(pluginID: pluginID)
        keyboard.query = nil
        setExpanded(true)
        holdUnlessHovered()
    }

    /// A click on a plugin's tile or strip icon in the home. Outside edit mode it opens the plugin's
    /// screen (`open(pluginID:)`); in edit mode a strip icon puts the plugin on the grid
    /// (`HomeModel.add(_:)`), while a tile is moved, resized or removed with its own controls.
    func tapHomePlugin(_ pluginID: String) {
        guard home.plugin(pluginID) != nil else { return }
        if home.isEditing {
            if home.layout.tile(for: pluginID) == nil { home.add(pluginID) }
        } else {
            open(pluginID: pluginID)
        }
    }

    private func holdUnlessHovered() {
        if isExpanded && !isHovering { isHeldOpen = true }
    }

    /// From a plugin's screen back to the home.
    func back() {
        screen = .home
    }

    /// Esc in the expanded notch: leaves edit mode, then a plugin's screen, then collapses.
    func escape() {
        guard state == .expanded else { return }
        if home.isEditing {
            home.finishEditing()
        } else if screen != .home {
            back()
        } else {
            setExpanded(false)
        }
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
        if !expanded {
            screen = .home
            home.finishEditing()
            keyboard.reset()
            isHeldOpen = false
        }
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

    /// Removes everything `pluginID` shows: its live activities, HUD and takeover, and answers its
    /// waiting attention requests with `.cancelled`. Called when the plugin is turned off.
    func withdraw(from pluginID: String) {
        activities = activities.filter { $0.key.pluginID != pluginID }
        if hud?.pluginID == pluginID { hud = nil }
        if takeover?.pluginID == pluginID { takeover = nil }
        for pending in attentions where pending.pluginID == pluginID {
            respond(.cancelled, to: pending.id)
        }
        scheduleExpiry()
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
        open(pluginID: pluginID)
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
