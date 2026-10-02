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
/// Attention requests queue in order and only the first is shown. A notice's display time starts
/// when it is shown, so one queued behind a longer request or held by a takeover still shows for its
/// full time; a request that waits for an answer keeps the timeout it was asked with. No notice is
/// dropped before it is shown. The queue stays short because a plugin cancels a source's older
/// notice when that source sends a newer one, and a cancelled request leaves the queue by its id.
/// A plugin that collapses the notch after the user answered one of its requests (a jump to a
/// terminal, however long it takes) folds it fully: the rest of the queue, including a notice that
/// already shows, is held for `collapseHold` before the next request shows, with the same timing rules
/// as behind a takeover. The answer allows one such collapse until another request is answered, or
/// the folded notch is opened while no request shows (the pointer, the hotkey, a link or a plugin).
/// A request timing out does not end it, nor does an opening under a shown request, nor a hover
/// whose open intent began (the pointer entered) before the answer, even if nothing shows when it
/// opens the notch. A hover whose open intent began before such a collapse does not open the notch
/// at all: the user has not reopened it since, and the pointer has to enter it again.
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
        /// When it times out. A request that waits for an answer counts from when it was asked; a
        /// notice counts from when it is shown, and has none while it waits or a takeover covers it.
        fileprivate(set) var deadline: ContinuousClock.Instant?
        fileprivate let continuation: CheckedContinuation<AttentionResponse, Never>

        /// A notice only tells the user something (title, message, buttons). A request that hands a
        /// question over from elsewhere (`releaseTitle`), offers choices or takes text waits for an
        /// answer. NotchKit has no field for this, so the host reads it from the request.
        var isNotice: Bool {
            request.releaseTitle == nil && request.choices.isEmpty && request.textField == nil
        }
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

    /// How long the queue stays hidden after a plugin collapsed the notch on its own answer before
    /// the next request shows.
    static let collapseHold: Duration = .milliseconds(1500)

    private var activities: [ActivityKey: PostedActivity] = [:]
    /// Waiting requests, oldest first; only the first is shown.
    private var attentions: [PendingAttention] = []
    /// Until when the queue stays hidden after a plugin collapsed the notch on its own answer.
    private var queueHeldUntil: ContinuousClock.Instant?
    /// When a plugin last collapsed the notch on its own answer; a hover intent that began by then
    /// does not open the notch.
    @ObservationIgnored private var answerCollapsedAt: ContinuousClock.Instant?
    /// The plugin whose request the user answered last and when, while its `collapse()` still belongs
    /// to that answer: until it collapses, another request is answered, or the notch opens while no
    /// request shows, other than by a hover whose intent began before the answer.
    @ObservationIgnored private var lastAnswer: (pluginID: String, at: ContinuousClock.Instant)?
    private var postCount = 0
    private var attentionCount = 0

    /// The host's clock: deadlines, answers and the window's hover intents are timed on it.
    @ObservationIgnored let now: @MainActor () -> ContinuousClock.Instant
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
        if !attentions.isEmpty && queueHeldUntil == nil { return .attention }
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
    /// - Parameter intentBegan: when the pointer entered the notch for this hover, on `now`; a hover
    ///   that began before the last answer does not end its collapse, and one that began before the
    ///   collapse itself does not open the notch.
    func setHovering(_ hovering: Bool, intentBegan: ContinuousClock.Instant? = nil) {
        isHovering = hovering
        if hovering { isHeldOpen = false }
        if hovering, let intentBegan, let answerCollapsedAt, intentBegan <= answerCollapsedAt { return }
        setExpanded(hovering, intentBegan: intentBegan)
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
        // A timeout or a cancellation is nobody's answer, so the last answer keeps its collapse.
        if response != .timedOut && response != .cancelled { lastAnswer = (pending.pluginID, now()) }
        pending.continuation.resume(returning: response)
        startShownNotice()
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
        if let queueHeldUntil, queueHeldUntil <= current { self.queueHeldUntil = nil }
        for pending in attentions where pending.deadline.map({ $0 <= current }) ?? false {
            respond(.timedOut, to: pending.id)
        }
        startShownNotice()
        scheduleExpiry()
    }

    /// Starts the display time of the notice the notch now shows. A takeover or a held queue hides it,
    /// so a notice hidden that way gets its full time again once it shows.
    private func startShownNotice() {
        guard let first = attentions.first, first.isNotice else { return }
        if takeover != nil || queueHeldUntil != nil {
            if first.deadline != nil { attentions[0].deadline = nil }
        } else if first.deadline == nil, let timeout = first.request.timeout {
            attentions[0].deadline = now() + timeout
        }
    }

    private func setExpanded(_ expanded: Bool, intentBegan: ContinuousClock.Instant? = nil) {
        guard pinnedExpansion == nil else { return }
        // Opening the folded notch ends the last answer's collapse, unless the user did not open it
        // after the answer: a request covers it, or the hover intent began before the answer and
        // only fires after it. An opening with no intent time (a plugin, a link, a key) ends it.
        if expanded && !isExpanded && state != .attention, let lastAnswer,
           intentBegan.map({ $0 > lastAnswer.at }) ?? true {
            self.lastAnswer = nil
        }
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
            + [hud?.deadline, takeover?.deadline, queueHeldUntil].compactMap { $0 }
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
        startShownNotice()
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
        startShownNotice()
        scheduleExpiry()
    }

    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse {
        if Task.isCancelled { return .cancelled }
        attentionCount += 1
        let id = attentionCount
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var pending = PendingAttention(id: id, pluginID: pluginID, request: request, deadline: nil, continuation: continuation)
                // A notice's time starts when it is shown (`startShownNotice()`).
                if !pending.isNotice { pending.deadline = request.timeout.map { now() + $0 } }
                attentions.append(pending)
                startShownNotice()
                scheduleExpiry()
            }
        } onCancel: {
            Task { @MainActor in self.respond(.cancelled, to: id) }
        }
    }

    func expand(toTabOf pluginID: String) {
        open(pluginID: pluginID)
    }

    /// The first collapse after the user answered one of this plugin's requests, however late it
    /// comes, also holds the rest of the queue for `collapseHold`, so the notch is left folded instead
    /// of showing the next request at once. A notice already showing is hidden and gets its full time
    /// when it shows again; nothing leaves the queue.
    func collapse(from pluginID: String) {
        setExpanded(false)
        guard lastAnswer?.pluginID == pluginID else { return }
        lastAnswer = nil
        let collapsedAt = now()
        answerCollapsedAt = collapsedAt
        queueHeldUntil = collapsedAt + Self.collapseHold
        startShownNotice()
        scheduleExpiry()
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
