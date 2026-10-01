import AppKit
import HookBridge
import NotchKit
import SwiftUI

/// What the plugin knows about one Claude Code session.
struct SessionRecord: Hashable {
    var terminal: TerminalLocation?
    var cwd: String?
    /// The session finished its turn and said so; Claude Code's idle reminder (`idle_prompt`) in the
    /// same pause adds no alert. A prompt, a request or a new session starts the next pause.
    var alertedPause = false
    /// The session's requests that wait for the user, oldest first.
    var waits: [OpenWait] = []
}

/// A request of a Claude Code session that waits for the user: held in the notch, or handed to the
/// terminal (released, or its wait ran out) and not answered there yet.
struct OpenWait: Hashable {
    let id: Int
    let state: AgentSessionState
    /// The tool call the request is about. PreToolUse names it by `tool_use_id`; PermissionRequest
    /// carries no id, so its call is known by tool name and input.
    let toolUseID: String?
    let tool: String?
    let input: JSONValue?
    var released = false

    /// Whether the call a PostToolUse or PostToolUseFailure `payload` ends is this request's.
    func isCall(_ payload: JSONValue) -> Bool {
        if let toolUseID, let ended = payload["tool_use_id"]?.string { return toolUseID == ended }
        return tool == payload["tool_name"]?.string && input == payload["tool_input"]
    }
}

/// Turns Claude Code hook messages into notch requests: records where each session runs, makes the
/// notch glow with the Claude mark when a session waits for input, finishes its turn or ends, and
/// takes the user to the session's terminal from there. Permission requests and AskUserQuestion are answered in the notch
/// within the configured wait, or handed back to the terminal.
@MainActor
final class ClaudeBridge {
    static let jumpButtonID = "jump"
    static let allowButtonID = "allow"
    static let denyButtonID = "deny"
    static let sendDenialButtonID = "send-denial"
    /// Opens the Agents screen, where an operation too long for the notch is shown and allowed.
    static let detailsButtonID = "details"
    /// Several questions: one answer field per question on the Agents screen.
    static let typeAnswersButtonID = "type-answers"
    static let sendAnswersButtonID = "send-answers"
    static let releaseTitle = "터미널에서 답하기"
    /// Sent to Claude when the user denies without writing a reason.
    static let defaultDenial = "사용자가 노치에서 거부했어요."
    /// Claude's orange.
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
    /// How long a notice stays. Waiting requests queue in the notch and their time runs while they
    /// wait, so a notice must not stay forever.
    static let noticeTimeout: Duration = .seconds(30)
    /// `notification_type`s that mean Claude Code waits for the user. `permission_prompt` is left out:
    /// the PermissionRequest hook brings the request itself to the notch, and one request must not
    /// glow twice. A notification without a type is shown.
    static let waitingNotificationTypes: Set<String> = ["idle_prompt", "agent_needs_input", "elicitation_dialog"]

    /// Requests shown in full on the Agents screen.
    let screen = AgentsScreenModel()
    private let context: NotchContext
    private let activator: any TerminalActivating
    /// The marks alerts show; nil shows the agent's symbol.
    private let logos: (any AgentLogoProviding)?
    /// How long the notch waits for an answer before the request goes back to the terminal.
    private let wait: @MainActor () -> Duration
    private(set) var sessions: [String: SessionRecord] = [:]
    /// The notice each session shows; a newer one replaces it.
    private var notices: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var noticeCount = 0
    /// Requests whose hook waits for a decision, by number.
    private var decisions: [Int: Task<HookDecision?, Never>] = [:]
    private var decisionCount = 0
    private var waitCount = 0

    init(
        context: NotchContext,
        activator: any TerminalActivating,
        logos: (any AgentLogoProviding)? = nil,
        wait: @escaping @MainActor () -> Duration = { .seconds(ApprovalWait.defaultSeconds) }
    ) {
        self.context = context
        self.activator = activator
        self.logos = logos
        self.wait = wait
    }

    /// Handles a message from the socket: a notice, or a request answered through `reply`. When the
    /// helper goes away first (the user answered in the terminal), the request leaves the notch.
    func handle(_ message: HookMessage, reply: HookReply?) {
        guard let reply else {
            receive(message)
            return
        }
        decisionCount += 1
        let id = decisionCount
        let task = Task { await decide(message) }
        decisions[id] = task
        reply.onClose { task.cancel() }
        Task {
            let decision = await task.value
            decisions[id] = nil
            reply.send(decision)
        }
    }

    /// The user's decision on a permission request or a question, or nil to leave it to the terminal.
    func decide(_ message: HookMessage) async -> HookDecision? {
        let sessionID = message.payload["session_id"]?.string ?? ""
        record(sessionID, message)
        let wait = track(sessionID, message)
        let title = projectName(sessionID, message)
        let decision: HookDecision?
        switch message.event {
        case .permissionRequest:
            decision = await decidePermission(message, title: title)
        case .preToolUse:
            decision = await answerQuestions(message, title: title)
        case .sessionStart, .userPromptSubmit, .stop, .notification, .sessionEnd, .postToolUse, .postToolUseFailure:
            decision = nil
        }
        guard let wait else { return decision }
        if decision != nil || Task.isCancelled {
            // Answered in the notch, or in the terminal while the notch held it (the hook went away
            // and cancelled this task).
            endWait(wait, of: sessionID)
        } else if let index = sessions[sessionID]?.waits.firstIndex(where: { $0.id == wait }) {
            // Released or timed out, the terminal asks now, so the session still waits. Claude Code
            // fires no hook when the user answers there, so the time between that answer and the
            // tool's end cannot be observed: the wait ends with the tool's own PostToolUse or
            // PostToolUseFailure, or with the session's next event of any other kind, and until then
            // the row keeps its waiting state.
            sessions[sessionID]?.waits[index].released = true
        }
        return decision
    }

    /// Handles one hook message. Returns the task that shows its notice, when it has one.
    @discardableResult
    func receive(_ message: HookMessage) -> Task<Void, Never>? {
        let payload = message.payload
        let sessionID = payload["session_id"]?.string ?? ""
        record(sessionID, message)
        track(sessionID, message)
        let title = projectName(sessionID, message)
        switch message.event {
        case .sessionStart, .userPromptSubmit, .postToolUse, .postToolUseFailure:
            return nil
        case .sessionEnd:
            // Every end alerts, /clear's too: it ends this conversation, and the next one in the same
            // terminal is a new session.
            return notify(sessionID, title: title, message: "Claude Code 세션이 끝났어요.")
        case .stop:
            sessions[sessionID]?.alertedPause = true
            return notify(sessionID, title: title, message: "Claude Code가 작업을 마쳤어요.")
        case .notification:
            let type = payload["notification_type"]?.string
            if let type, !Self.waitingNotificationTypes.contains(type) {
                return nil
            }
            // The finished turn's alert already told the user this session waits. The other waiting
            // types come within a turn, so they always alert.
            if type == "idle_prompt", sessions[sessionID]?.alertedPause == true { return nil }
            return notify(sessionID, title: title, message: payload["message"]?.string ?? "Claude Code가 입력을 기다려요.")
        case .permissionRequest, .preToolUse:
            return nil
        }
    }

    /// Withdraws every notice and request. Called when the plugin is turned off.
    func cancelAll() {
        for notice in notices.values {
            notice.task.cancel()
        }
        notices.removeAll()
        for decision in decisions.values {
            decision.cancel()
        }
        decisions.removeAll()
        screen.cancelAll()
    }

    /// 허용 or 거부 for one tool call. 거부 then asks for a message to Claude in a text field. The
    /// notch offers 허용 only for an operation it shows in full; anything longer goes to the Agents
    /// screen (자세히 보기), which shows all of it and is where it is allowed.
    private func decidePermission(_ message: HookMessage, title: String) async -> HookDecision? {
        let tool = message.payload["tool_name"]?.string ?? "도구"
        // AskUserQuestion is answered through its PreToolUse hook.
        guard tool != "AskUserQuestion" else { return nil }
        let detail = OperationDetail(tool: tool, input: message.payload["tool_input"])
        let wait = wait()
        let deadline = ContinuousClock.now + wait
        let response = await context.requestAttention(AttentionRequest(
            title: "\(title) · \(tool)",
            message: detail.notchText ?? detail.headline,
            accent: Self.accent,
            sourceIcon: terminalIcon(message),
            buttons: [
                AttentionButton(id: Self.denyButtonID, title: "거부", role: .destructive),
                detail.notchText == nil
                    ? AttentionButton(id: Self.detailsButtonID, title: "자세히 보기", role: .primary)
                    : AttentionButton(id: Self.allowButtonID, title: "허용", role: .primary),
            ],
            releaseTitle: Self.releaseTitle,
            timeout: wait
        ))
        guard case .answered(let answer) = response else { return nil }
        if answer.buttonID == Self.allowButtonID, detail.notchText != nil { return .allow }
        if answer.buttonID == Self.detailsButtonID {
            switch await showOnScreen("\(title) · \(tool)", .permission(detail), until: deadline) {
            case .allow: return .allow
            case .deny(let reason): return .deny(message: Self.denial(reason))
            default: return nil
            }
        }
        guard answer.buttonID == Self.denyButtonID else { return nil }
        let left = deadline - .now
        guard left > .zero else { return nil }
        let reason = await context.requestAttention(AttentionRequest(
            title: "\(title) · \(tool) 거부",
            message: "Claude에게 거부하는 이유를 알려 주세요. 비워 두면 이유 없이 거부해요.",
            accent: Self.accent,
            sourceIcon: terminalIcon(message),
            buttons: [AttentionButton(id: Self.sendDenialButtonID, title: "거부", role: .destructive)],
            textField: AttentionTextField(placeholder: "거부하는 이유"),
            releaseTitle: Self.releaseTitle,
            timeout: left
        ))
        // Return in the text field answers without a button.
        guard case .answered(let written) = reason else { return nil }
        return .deny(message: Self.denial(written.text ?? ""))
    }

    /// AskUserQuestion: each question's options (one or several). A single question also takes free
    /// text in the notch; several questions each get their own answer field on the Agents screen, so
    /// one typed value never answers them all. A question left without an answer goes to the terminal.
    private func answerQuestions(_ message: HookMessage, title: String) async -> HookDecision? {
        guard message.payload["tool_name"]?.string == "AskUserQuestion",
              let questions = Question.parse(message.payload["tool_input"]) else { return nil }
        let single = questions.count == 1
        let wait = wait()
        let deadline = ContinuousClock.now + wait
        let response = await context.requestAttention(AttentionRequest(
            title: "\(title) · Claude의 질문",
            message: "",
            accent: Self.accent,
            sourceIcon: terminalIcon(message),
            // Any button replaces the notch's own 보내기, so several questions bring their own.
            buttons: single ? [] : [
                AttentionButton(id: Self.typeAnswersButtonID, title: "직접 입력하기"),
                AttentionButton(id: Self.sendAnswersButtonID, title: "보내기", role: .primary),
            ],
            choices: questions.enumerated().map { index, question in
                AttentionChoices(id: String(index), prompt: question.text, options: question.options, allowsMultiple: question.multiple)
            },
            textField: single ? AttentionTextField(placeholder: "직접 입력해서 답해요") : nil,
            releaseTitle: Self.releaseTitle,
            timeout: wait
        ))
        guard case .answered(let answer) = response else { return nil }
        var picked: [Int: [String]] = [:]
        for index in questions.indices {
            if let options = answer.choices[String(index)], !options.isEmpty { picked[index] = options }
        }
        let typed = single ? [0: answer.text ?? ""] : [:]
        if answer.buttonID != Self.typeAnswersButtonID, let answers = Question.answers(questions, picked: picked, typed: typed) {
            return .answers(answers)
        }
        guard !single else { return nil }
        // Typed answers, or questions still open: one field per question on the Agents screen.
        let result = await showOnScreen("\(title) · Claude의 질문", .questions(questions, picked: picked), until: deadline)
        guard case .answers(let screenPicked, let screenTyped) = result else { return nil }
        return Question.answers(questions, picked: screenPicked, typed: screenTyped).map(HookDecision.answers)
    }

    /// Opens the Agents screen on the request and waits there until the user answers, hands it to the
    /// terminal or the wait that began in the notch ends.
    private func showOnScreen(_ title: String, _ content: ScreenItem.Content, until deadline: ContinuousClock.Instant) async -> ScreenResponse {
        guard deadline > .now else { return .timedOut }
        context.expand()
        return await screen.show(title: title, content: content, accent: Self.accent, takesDenyReason: true, until: deadline)
    }

    private static func denial(_ reason: String) -> String {
        let text = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? defaultDenial : text
    }

    private func terminalIcon(_ message: HookMessage) -> Image? {
        let sessionID = message.payload["session_id"]?.string ?? ""
        return sessions[sessionID]?.terminal.flatMap(Self.appIcon)
    }

    func notificationRequest(sessionID: String, title: String, message: String) -> AttentionRequest {
        let terminal = sessions[sessionID]?.terminal
        return AttentionRequest(
            title: title,
            message: message,
            accent: Self.accent,
            sourceIcon: AgentKind.claude.alertIcon(logos),
            buttons: [AttentionButton(id: Self.jumpButtonID, title: terminal == nil ? "노치 열기" : "터미널로 이동", role: .primary)],
            timeout: Self.noticeTimeout
        )
    }

    private func record(_ sessionID: String, _ message: HookMessage) {
        guard !sessionID.isEmpty else { return }
        var record = sessions[sessionID] ?? SessionRecord()
        // Every event carries the terminal the hook found, so a session seen before the app started
        // is known from its next event on.
        if let terminal = message.context.terminal {
            record.terminal = terminal
        }
        if let cwd = message.payload["cwd"]?.string {
            record.cwd = cwd
        }
        switch message.event {
        case .stop, .notification:
            break
        case .sessionStart, .userPromptSubmit, .permissionRequest, .preToolUse, .postToolUse, .postToolUseFailure, .sessionEnd:
            record.alertedPause = false
        }
        sessions[sessionID] = record
    }

    /// Moves the session's row on the Agents screen. Returns the wait a request opened.
    @discardableResult
    private func track(_ sessionID: String, _ message: HookMessage) -> Int? {
        guard !sessionID.isEmpty else { return nil }
        let key = Key(agent: .claude, id: sessionID)
        let state: AgentSessionState?
        var opened: Int?
        switch message.event {
        case .sessionEnd:
            sessions[sessionID]?.waits.removeAll()
            screen.sessions.remove(key)
            return nil
        case .sessionStart, .stop:
            endReleasedWaits(of: sessionID)
            state = .idle
        case .userPromptSubmit:
            endReleasedWaits(of: sessionID)
            state = .working
        case .notification:
            endReleasedWaits(of: sessionID)
            state = Self.waitingState(payload: message.payload)
        case .postToolUse, .postToolUseFailure:
            state = toolEnded(sessionID, message.payload)
        case .permissionRequest, .preToolUse:
            endReleasedWaits(of: sessionID)
            // AskUserQuestion waits through its PreToolUse hook.
            if message.event == .preToolUse {
                state = .awaitingAnswer
            } else {
                state = message.payload["tool_name"]?.string == "AskUserQuestion" ? nil : .awaitingApproval
            }
            opened = state.map { openWait(sessionID, $0, message.payload) }
        }
        screen.sessions.update(
            key, folder: projectName(sessionID, message), state: state,
            terminal: sessions[sessionID]?.terminal, pid: message.context.claudePID
        )
        return opened
    }

    private func openWait(_ sessionID: String, _ state: AgentSessionState, _ payload: JSONValue) -> Int {
        waitCount += 1
        sessions[sessionID]?.waits.append(OpenWait(
            id: waitCount, state: state, toolUseID: payload["tool_use_id"]?.string,
            tool: payload["tool_name"]?.string, input: payload["tool_input"]
        ))
        return waitCount
    }

    /// The request `id` of the session was answered. The session works again once no wait is left;
    /// otherwise it shows the wait still open.
    private func endWait(_ id: Int, of sessionID: String) {
        guard sessions[sessionID]?.waits.contains(where: { $0.id == id }) == true else { return }
        sessions[sessionID]?.waits.removeAll { $0.id == id }
        screen.sessions.answered(Key(agent: .claude, id: sessionID), waiting: sessions[sessionID]?.waits.last?.state)
    }

    /// Any later event of the session but another tool's end means the terminal no longer asks what
    /// was handed to it. Requests still held in the notch stay.
    private func endReleasedWaits(of sessionID: String) {
        sessions[sessionID]?.waits.removeAll(where: \.released)
    }

    /// A tool call of the session ended, done or failed: the request about that call ends. The
    /// session works again once no wait is left; another call's end leaves a waiting session as it is.
    private func toolEnded(_ sessionID: String, _ payload: JSONValue) -> AgentSessionState? {
        guard var waits = sessions[sessionID]?.waits, !waits.isEmpty else { return .working }
        guard let index = waits.firstIndex(where: { $0.isCall(payload) }) else { return nil }
        waits.remove(at: index)
        sessions[sessionID]?.waits = waits
        return waits.last?.state ?? .working
    }

    private typealias Key = AgentSession.Key

    /// The state a Notification puts the session in: a question it asks (an MCP server's form, a
    /// subagent that needs input) or Claude Code's idle reminder. Any other notice, or one without a
    /// type, keeps the state.
    private static func waitingState(payload: JSONValue) -> AgentSessionState? {
        switch payload["notification_type"]?.string {
        case "elicitation_dialog", "agent_needs_input": .awaitingAnswer
        case "idle_prompt": .idle
        default: nil
        }
    }

    /// The last folder name of the session's working folder, or of the project folder.
    private func projectName(_ sessionID: String, _ message: HookMessage) -> String {
        let folder = message.payload["cwd"]?.string ?? sessions[sessionID]?.cwd ?? message.context.projectDir
        guard let folder, !folder.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    private func notify(_ sessionID: String, title: String, message: String) -> Task<Void, Never> {
        notices[sessionID]?.task.cancel()
        noticeCount += 1
        let id = noticeCount
        let request = notificationRequest(sessionID: sessionID, title: title, message: message)
        let task = Task { [context] in
            let response = await context.requestAttention(request)
            if case .answered(let answer) = response, answer.buttonID == Self.jumpButtonID {
                self.jump(to: sessionID)
            }
            if self.notices[sessionID]?.id == id {
                self.notices[sessionID] = nil
            }
        }
        notices[sessionID] = (id, task)
        return task
    }

    /// Brings the session's terminal forward, or opens the notch when the terminal is unknown or gone.
    private func jump(to sessionID: String) {
        if let terminal = sessions[sessionID]?.terminal, activator.activate(terminal) {
            return
        }
        context.expand()
    }

    static func appIcon(_ terminal: TerminalLocation) -> Image? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID) else { return nil }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
