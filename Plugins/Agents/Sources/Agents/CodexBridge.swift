import HookBridge
import NotchKit
import SwiftUI

/// Speaks codex's app-server protocol (JSON-RPC without a `jsonrpc` member, shapes from codex-cli
/// 0.153.4's `generate-json-schema`) for one connection at a time: initializes, subscribes to every
/// loaded thread and to each new one (`thread/started`), and turns the server's requests into notch
/// requests. Command and file-change approvals are answered `accept`, `acceptForSession` or
/// `decline`; questions are answered by question id. A request answered elsewhere
/// (`serverRequest/resolved`), one the user hands back to the terminal and one that times out leave
/// the notch unanswered, so the `codex` TUI keeps its own prompt. A finished or failed turn and a
/// closed thread glow with the Codex mark and the project name, and from there the user jumps to the
/// TUI's terminal.
@MainActor
final class CodexBridge {
    nonisolated static let allowButtonID = "allow"
    nonisolated static let allowForSessionButtonID = "allow-session"
    nonisolated static let denyButtonID = "deny"
    nonisolated static let detailsButtonID = "details"
    nonisolated static let typeAnswersButtonID = "type-answers"
    nonisolated static let sendAnswersButtonID = "send-answers"
    nonisolated static let jumpButtonID = "jump"
    /// How many times a refused `thread/loaded/list` or `thread/resume` is sent before the bridge
    /// reports the sessions it could not follow.
    static let discoveryAttempts = 4
    /// A neutral slate, so codex's requests never look like Claude Code's and borrow no brand colour.
    static let accent = Color(red: 0.44, green: 0.53, blue: 0.62)
    static let clientInfo: JSONValue = .object([
        "name": .string("notch-the-rock"),
        "title": .string("NotchTheRock"),
        "version": .string(AgentsPlugin.manifest.version),
    ])

    /// Requests shown in full; the plugin passes the screen its tab shows.
    let screen: AgentsScreenModel
    private let context: NotchContext
    private let activator: any TerminalActivating
    /// The marks alerts show; nil shows the agent's symbol.
    private let logos: (any AgentLogoProviding)?
    /// The terminal of the `codex` TUI working in a folder, looked up when it is needed.
    private let terminal: @MainActor (String?) -> TerminalLocation?
    private let wait: @MainActor () -> Duration
    private let initializeTimeout: Duration
    /// The wait before discovery call number `attempt` (from 0) is sent again after the server refused it.
    private let retryDelay: @MainActor (Int) -> Duration
    /// Thread folders by thread id, kept across connections.
    private(set) var threads: [String: String] = [:]
    /// The terminal found when each thread joined, kept across connections like `threads`. Its own
    /// TUI's terminal: a lookup by folder later may find another TUI in the same folder.
    private var terminals: [String: TerminalLocation] = [:]
    /// The threads that joined on this connection (started, or listed and resumed) and have not
    /// closed. The Agents screen's list may drop a silent thread's row; this does not, so the
    /// thread's end still alerts, once.
    private var joined: Set<String> = []

    // One connection's state; `close()` clears it.
    private var send: (@MainActor (JSONValue) -> Void)?
    private var ready: (@MainActor () -> Void)?
    private var failed: (@MainActor (String) -> Void)?
    private var incomplete: (@MainActor (String) -> Void)?
    /// Gives up on the connection when `initialize` goes unanswered.
    private var initializing: Task<Void, Never>?
    /// Discovery calls the server refused, waiting to be sent again; `close()` cancels them.
    private var retries: [Task<Void, Never>] = []
    /// Counts connections, so an answer never goes out on a later connection than its request's.
    private var connection = 0
    private var callCount = 0
    private var calls: [Int: Call] = [:]
    private var resumed: Set<String> = []
    /// The `changes` of each file-change item, from `item/started` and `item/fileChange/patchUpdated`.
    private var fileChanges: [String: [JSONValue]] = [:]
    /// Server requests waiting for the user, by request id.
    private var pending: [JSONValue: (number: Int, task: Task<Void, Never>)] = [:]
    private var pendingCount = 0
    /// The requests each thread waits on, the notch's and the TUI's alike, oldest first. A thread
    /// works again once none of its requests is left.
    private var waits: [(request: JSONValue, thread: String, state: AgentSessionState)] = []
    private var notices: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var noticeCount = 0

    /// A call and, for discovery, how many times the server refused it before.
    private enum Call {
        case initialize
        case list(cursor: String?, attempt: Int)
        case resume(String, attempt: Int)
    }

    init(
        context: NotchContext,
        activator: any TerminalActivating,
        screen: AgentsScreenModel = AgentsScreenModel(),
        terminal: @escaping @MainActor (String?) -> TerminalLocation?,
        logos: (any AgentLogoProviding)? = nil,
        initializeTimeout: Duration = .seconds(10),
        wait: @escaping @MainActor () -> Duration = { .seconds(ApprovalWait.defaultSeconds) },
        retryDelay: @escaping @MainActor (Int) -> Duration = CodexSupervisor.backoff(attempt:)
    ) {
        self.context = context
        self.activator = activator
        self.screen = screen
        self.terminal = terminal
        self.logos = logos
        self.wait = wait
        self.initializeTimeout = initializeTimeout
        self.retryDelay = retryDelay
    }

    /// A new connection: `send` writes one message to it, `ready` runs once the server accepted
    /// `initialize`, and `failed` once the bridge gave up on the connection because the server refused
    /// `initialize` or left it unanswered for `initializeTimeout`; the bridge is closed by then.
    /// `incomplete` runs when the server refused listing or following sessions `discoveryAttempts`
    /// times: the connection stays, without those sessions. Starts with `initialize`.
    func open(
        send: @escaping @MainActor (JSONValue) -> Void,
        ready: @escaping @MainActor () -> Void = {},
        failed: @escaping @MainActor (String) -> Void = { _ in },
        incomplete: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        close()
        connection += 1
        self.send = send
        self.ready = ready
        self.failed = failed
        self.incomplete = incomplete
        let connection = connection
        initializing = Task { [weak self, initializeTimeout] in
            try? await Task.sleep(for: initializeTimeout)
            guard !Task.isCancelled, let self, self.connection == connection else { return }
            self.fail("app-server가 초기화 요청에 답하지 않았어요.")
        }
        call(.initialize, "initialize", .object([
            "clientInfo": Self.clientInfo,
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ]))
    }

    /// The connection is gone: its requests can no longer be answered, so they leave the notch.
    func close() {
        send = nil
        ready = nil
        failed = nil
        incomplete = nil
        initializing?.cancel()
        initializing = nil
        for retry in retries {
            retry.cancel()
        }
        retries.removeAll()
        calls.removeAll()
        callCount = 0
        resumed.removeAll()
        joined.removeAll()
        waits.removeAll()
        fileChanges.removeAll()
        for request in pending.values {
            request.task.cancel()
        }
        pending.removeAll()
        // Without a connection nothing tells how the sessions go on; the next one lists them again.
        screen.sessions.removeAll(.codex)
    }

    /// Closes the connection's state, then tells the link why it should drop the connection.
    private func fail(_ reason: String) {
        let failed = failed
        close()
        failed?(reason)
    }

    /// Withdraws every request and notice. Called when the plugin is turned off.
    func cancelAll() {
        close()
        for notice in notices.values {
            notice.task.cancel()
        }
        notices.removeAll()
    }

    /// One message from the server. Returns the task that asks the user, when it asks something.
    @discardableResult
    func receive(_ message: JSONValue) -> Task<Void, Never>? {
        // Only an open connection's messages count.
        guard send != nil else { return nil }
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            if let id = message["id"] {
                return request(id, method, params)
            }
            return notification(method, params)
        }
        guard let id = message["id"] else { return nil }
        guard let number = Self.callNumber(id), let call = calls.removeValue(forKey: number) else {
            context.log.error("Ignored a codex app-server response to no pending call: id \(Self.encode(id))")
            return nil
        }
        if let error = message["error"] {
            context.log.error("codex app-server refused a request: \(Self.encode(error))")
            switch call {
            case .initialize: fail("app-server가 초기화 요청을 거절했어요.")
            case .list(let cursor, let attempt): retry(after: attempt) { $0.list(cursor: cursor, attempt: attempt + 1) }
            case .resume(let thread, let attempt): retry(after: attempt) { $0.subscribe(thread, attempt: attempt + 1) }
            }
            return nil
        }
        response(call, message["result"] ?? .null)
        return nil
    }

    /// The call a response answers: only an integer id our calls use, exactly as sent. A fraction,
    /// a number beyond `Int` or a string never matches.
    static func callNumber(_ id: JSONValue) -> Int? {
        guard case .number(let value) = id else { return nil }
        return Int(exactly: value)
    }

    static func encode(_ message: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: encoder.encode(message), as: UTF8.self)) ?? "null"
    }

    // MARK: Calls and responses

    private func call(_ kind: Call, _ method: String, _ params: JSONValue) {
        guard let send else { return }
        callCount += 1
        calls[callCount] = kind
        send(.object(["id": .number(Double(callCount)), "method": .string(method), "params": params]))
    }

    private func response(_ kind: Call, _ result: JSONValue) {
        switch kind {
        case .initialize:
            initializing?.cancel()
            initializing = nil
            send?(.object(["method": .string("initialized")]))
            list(cursor: nil)
            ready?()
        case .list:
            if let cursor = result["nextCursor"]?.string {
                list(cursor: cursor)
            }
            for thread in result["data"]?.array?.compactMap(\.string) ?? [] {
                resume(thread)
            }
        case .resume(let thread, _):
            if let cwd = result["thread"]?["cwd"]?.string ?? result["cwd"]?.string {
                threads[thread] = cwd
            }
            // A thread in the middle of a turn is working; any other loaded thread waits for the user.
            join(thread, result["thread"]?["status"]?["type"]?.string == "active" ? .working : .idle)
        }
    }

    private func list(cursor: String?, attempt: Int = 0) {
        call(.list(cursor: cursor, attempt: attempt), "thread/loaded/list", .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
    }

    /// Subscribes to a thread once per connection. A thread stays in `resumed` while a refused resume
    /// waits to be sent again and after the attempts ran out, so it is never resumed twice at once.
    private func resume(_ thread: String) {
        guard resumed.insert(thread).inserted else { return }
        subscribe(thread, attempt: 0)
    }

    /// Only the id is sent: any other member would change the settings of the TUI's live thread.
    private func subscribe(_ thread: String, attempt: Int) {
        call(.resume(thread, attempt: attempt), "thread/resume", .object(["threadId": .string(thread), "excludeTurns": .bool(true)]))
    }

    /// Sends a refused discovery call again after the backoff, on the same connection only. Once it was
    /// refused `discoveryAttempts` times the sessions it would have found stay out of the notch, and
    /// `incomplete` says so.
    private func retry(after attempt: Int, _ again: @escaping @MainActor (CodexBridge) -> Void) {
        guard attempt + 1 < Self.discoveryAttempts else {
            incomplete?("app-server가 Codex 세션 정보를 주지 않아서 일부 세션이 노치에 보이지 않아요.")
            return
        }
        let connection = connection
        let delay = retryDelay(attempt)
        retries.append(Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.connection == connection, self.send != nil else { return }
            again(self)
        })
    }

    // MARK: Notifications

    private func notification(_ method: String, _ params: JSONValue) -> Task<Void, Never>? {
        switch method {
        case "thread/started":
            guard let thread = params["thread"], let id = thread["id"]?.string else { return nil }
            if let cwd = thread["cwd"]?.string { threads[id] = cwd }
            join(id, .idle)
            resume(id)
        case "item/started" where params["item"]?["type"]?.string == "fileChange":
            if let item = params["item"], let id = item["id"]?.string {
                fileChanges[id] = item["changes"]?.array
            }
        case "item/fileChange/patchUpdated":
            if let id = params["itemId"]?.string {
                fileChanges[id] = params["changes"]?.array
            }
        case "item/completed":
            if let id = params["item"]?["id"]?.string { fileChanges[id] = nil }
        case "serverRequest/resolved":
            if let id = params["requestId"] {
                pending.removeValue(forKey: id)?.task.cancel()
            }
            // Answered elsewhere, in the TUI for one.
            if let thread = params["threadId"]?.string {
                endWait(params["requestId"], of: thread)
            }
        case "turn/started":
            if let thread = params["threadId"]?.string { track(thread, .working) }
        case "thread/closed":
            guard let thread = params["threadId"]?.string else { return nil }
            waits.removeAll { $0.thread == thread }
            screen.sessions.remove(AgentSession.Key(agent: .codex, id: thread))
            // One alert per thread that joined, whether or not the list still shows it. The TUI may
            // be gone already; the alert takes the user to the terminal the thread joined in.
            guard joined.remove(thread) != nil else { return nil }
            return notify(thread, message: "Codex 세션이 끝났어요.", saved: terminals.removeValue(forKey: thread))
        case "turn/completed":
            guard let thread = params["threadId"]?.string else { return nil }
            waits.removeAll { $0.thread == thread }
            track(thread, .idle)
            switch params["turn"]?["status"]?.string {
            case "completed": return notify(thread, message: "Codex가 작업을 마쳤어요.", saved: terminals[thread])
            case "failed": return notify(thread, message: "Codex 작업이 오류로 멈췄어요.", saved: terminals[thread])
            default: return nil
            }
        default:
            break
        }
        return nil
    }

    // MARK: Requests

    /// Every request leaves `pending` one way: answered, left to the terminal, answered elsewhere
    /// (`serverRequest/resolved`), replaced by a request with its id, or dropped with its connection.
    /// Each way but the first cancels its task, and a cancelled task neither asks nor answers.
    private func request(_ id: JSONValue, _ method: String, _ params: JSONValue) -> Task<Void, Never>? {
        // A reused id: the server no longer means the older request, whatever the new one asks and
        // whether or not the notch takes it, so the older one leaves first.
        if let older = pending.removeValue(forKey: id) {
            older.task.cancel()
            context.log.error("codex app-server reused the request id \(Self.encode(id)); the older request was withdrawn")
        }
        // The session waits for the user whether or not the notch takes the request.
        let thread = params["threadId"]?.string
        if let thread {
            switch method {
            case "item/commandExecution/requestApproval", "item/fileChange/requestApproval": wait(on: id, thread, .awaitingApproval)
            case "item/tool/requestUserInput": wait(on: id, thread, .awaitingAnswer)
            default: break
            }
        }
        let ask: @MainActor () async -> JSONValue?
        switch method {
        case "item/commandExecution/requestApproval":
            ask = { await self.decideCommand(params).map { .object(["decision": .string($0)]) } }
        case "item/fileChange/requestApproval":
            ask = { await self.decideFileChange(params).map { .object(["decision": .string($0)]) } }
        case "item/tool/requestUserInput":
            guard let questions = CodexQuestion.parse(params["questions"]), !questions.contains(where: \.isSecret) else {
                // A secret typed into the notch would be shown in plain text: the terminal asks it.
                return nil
            }
            ask = { await self.answer(questions, params).map { .object(["answers": $0]) } }
        default:
            // Requests meant for the client that started the thread stay with it.
            return nil
        }
        pendingCount += 1
        let number = pendingCount
        let connection = connection
        let task = Task {
            // Withdrawn before it ran: the notch never shows it.
            var result: JSONValue?
            if !Task.isCancelled {
                result = await ask()
            }
            // Only the request still waiting under this id, on the connection it came from, answers.
            let current = !Task.isCancelled && self.connection == connection && self.pending[id]?.number == number
            if current, let result {
                self.send?(.object(["id": id, "result": result]))
                if let thread { self.endWait(id, of: thread) }
            }
            if self.pending[id]?.number == number {
                self.pending[id] = nil
            }
        }
        pending[id] = (number, task)
        return task
    }

    /// The thread waits on `request` until it is answered, in the notch or elsewhere.
    private func wait(on request: JSONValue, _ thread: String, _ state: AgentSessionState) {
        waits.removeAll { $0.request == request }
        waits.append((request, thread, state))
        track(thread, state)
    }

    /// `request` of `thread` was answered: the thread works again once none of its requests waits,
    /// and shows the one still open otherwise.
    private func endWait(_ request: JSONValue?, of thread: String) {
        waits.removeAll { $0.request == request }
        screen.sessions.answered(AgentSession.Key(agent: .codex, id: thread), waiting: waits.last { $0.thread == thread }?.state)
    }

    private func decideCommand(_ params: JSONValue) async -> String? {
        let detail = Self.commandDetail(params, threadFolder: threadFolder(params))
        let title = "\(projectName(params)) · \(params["kind"]?.string == "writeStdin" ? "터미널 입력" : "명령 실행")"
        let available = params["availableDecisions"]?.array?.compactMap(\.string)
        let allowsSession = available?.contains("acceptForSession") ?? true
        var buttons = [AttentionButton(id: Self.denyButtonID, title: "거부", role: .destructive)]
        if detail.notchText != nil {
            if allowsSession {
                buttons.append(AttentionButton(id: Self.allowForSessionButtonID, title: "이번 세션 동안 허용"))
            }
            buttons.append(AttentionButton(id: Self.allowButtonID, title: "허용", role: .primary))
        } else if !detail.sections.isEmpty {
            buttons.append(AttentionButton(id: Self.detailsButtonID, title: "자세히 보기", role: .primary))
        }
        return await decide(title: title, detail: detail, buttons: buttons, allowsSession: allowsSession, params: params)
    }

    private func decideFileChange(_ params: JSONValue) async -> String? {
        let title = "\(projectName(params)) · 파일 수정"
        var buttons = [AttentionButton(id: Self.denyButtonID, title: "거부", role: .destructive)]
        let detail: OperationDetail
        let changes = params["itemId"]?.string.flatMap { fileChanges[$0] }
        if let changes, let changed = Self.sections(changes) {
            var sections = changed
            if let root = params["grantRoot"]?.string { sections.append(.init(label: "이번 세션 동안 쓰기를 허용할 폴더", body: root)) }
            if let reason = params["reason"]?.string { sections.append(.init(label: "이유", body: reason)) }
            let names = changes.compactMap { $0["path"]?.string }.map { URL(fileURLWithPath: $0).lastPathComponent }
            detail = OperationDetail(
                tool: "파일 수정", sections: sections, notchText: nil,
                headline: "파일 \(changed.count)개를 바꿔요: \(names.joined(separator: ", ")). 자세히 보기에서 바뀌는 내용을 확인해 주세요."
            )
            buttons.append(AttentionButton(id: Self.detailsButtonID, title: "자세히 보기", role: .primary))
        } else {
            detail = OperationDetail(
                tool: "파일 수정", sections: [], notchText: nil,
                headline: changes == nil
                    ? "바뀌는 내용을 알 수 없어서 노치에서는 허용할 수 없어요. 터미널에서 확인해 주세요."
                    : "바뀌는 내용 중 읽지 못한 부분이 있어서 노치에서는 허용할 수 없어요. 터미널에서 확인해 주세요."
            )
        }
        // codex lets every file change be allowed for the session.
        return await decide(title: title, detail: detail, buttons: buttons, allowsSession: true, params: params)
    }

    /// Asks in the notch and, for 자세히 보기, on the Agents screen. Nil leaves the request to the TUI.
    private func decide(title: String, detail: OperationDetail, buttons: [AttentionButton], allowsSession: Bool, params: JSONValue) async -> String? {
        let wait = wait()
        let deadline = ContinuousClock.now + wait
        let response = await context.requestAttention(AttentionRequest(
            title: title,
            message: detail.notchText ?? detail.headline,
            accent: Self.accent,
            sourceIcon: icon(params),
            buttons: buttons,
            releaseTitle: ClaudeBridge.releaseTitle,
            timeout: wait
        ))
        guard case .answered(let answer) = response else { return nil }
        let offered = Set(buttons.map(\.id))
        switch answer.buttonID {
        case Self.denyButtonID?:
            return "decline"
        case Self.allowButtonID? where offered.contains(Self.allowButtonID):
            return "accept"
        case Self.allowForSessionButtonID? where offered.contains(Self.allowForSessionButtonID):
            return "acceptForSession"
        case Self.detailsButtonID? where offered.contains(Self.detailsButtonID):
            switch await showOnScreen(title, .permission(detail), allowsSession: allowsSession, until: deadline) {
            case .allow: return "accept"
            case .allowForSession where allowsSession: return "acceptForSession"
            case .deny: return "decline"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Options are picked in the notch; a single question also takes typed text there. Several
    /// questions typed out get one field each on the Agents screen. Answers go by question id.
    private func answer(_ questions: [CodexQuestion], _ params: JSONValue) async -> JSONValue? {
        let single = questions.count == 1
        let typable = questions.contains(where: \.takesText)
        let title = "\(projectName(params)) · Codex의 질문"
        let wait = wait()
        let deadline = ContinuousClock.now + wait
        let response = await context.requestAttention(AttentionRequest(
            title: title,
            message: "",
            accent: Self.accent,
            sourceIcon: icon(params),
            buttons: single ? [] : (typable ? [AttentionButton(id: Self.typeAnswersButtonID, title: "직접 입력하기")] : [])
                + [AttentionButton(id: Self.sendAnswersButtonID, title: "보내기", role: .primary)],
            choices: questions.map { AttentionChoices(id: $0.id, prompt: $0.prompt, options: $0.options) },
            textField: single && questions[0].takesText ? AttentionTextField(placeholder: "직접 입력해서 답해요") : nil,
            releaseTitle: ClaudeBridge.releaseTitle,
            timeout: wait
        ))
        guard case .answered(let reply) = response else { return nil }
        var picked: [Int: [String]] = [:]
        for (index, question) in questions.enumerated() {
            if let options = reply.choices[question.id], !options.isEmpty { picked[index] = options }
        }
        let typed = single ? [0: reply.text ?? ""] : [:]
        if reply.buttonID != Self.typeAnswersButtonID, let answers = CodexQuestion.answers(questions, picked: picked, typed: typed) {
            return answers
        }
        guard !single else { return nil }
        let result = await showOnScreen(title, .questions(questions.map(\.question), picked: picked), until: deadline)
        guard case .answers(let screenPicked, let screenTyped) = result else { return nil }
        return CodexQuestion.answers(questions, picked: screenPicked, typed: screenTyped)
    }

    private func showOnScreen(_ title: String, _ content: ScreenItem.Content, allowsSession: Bool = false, until deadline: ContinuousClock.Instant) async -> ScreenResponse {
        guard deadline > .now else { return .timedOut }
        context.expand()
        return await screen.show(title: title, content: content, accent: Self.accent, allowsSession: allowsSession, until: deadline)
    }

    // MARK: Notices and the terminal

    /// A thread started, or was listed and resumed: it joins. Its terminal is looked up only when
    /// none was saved for it: a rejoin after a reconnect keeps the one it joined in, since another TUI
    /// may work in the same folder by now. Only here: the lookup walks the running processes.
    private func join(_ thread: String, _ state: AgentSessionState) {
        joined.insert(thread)
        if terminals[thread] == nil, let found = terminal(threads[thread]) {
            terminals[thread] = found
        }
        track(thread, state)
    }

    /// Moves the thread's row on the Agents screen; a row that left the list comes back with the
    /// terminal the thread joined in.
    private func track(_ thread: String, _ state: AgentSessionState) {
        let folder = threads[thread].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent } ?? "Codex"
        screen.sessions.update(AgentSession.Key(agent: .codex, id: thread), folder: folder, state: state, terminal: terminals[thread])
    }

    /// `saved` is the terminal the thread joined in; the folder is looked up only without one.
    private func notify(_ thread: String, message: String, saved: TerminalLocation?) -> Task<Void, Never> {
        notices[thread]?.task.cancel()
        noticeCount += 1
        let id = noticeCount
        let found = saved ?? terminal(threads[thread])
        let request = AttentionRequest(
            title: projectName(.object(["threadId": .string(thread)])),
            message: message,
            accent: Self.accent,
            sourceIcon: AgentKind.codex.alertIcon(logos),
            buttons: [AttentionButton(id: Self.jumpButtonID, title: found == nil ? "노치 열기" : "터미널로 이동", role: .primary)],
            timeout: ClaudeBridge.noticeTimeout
        )
        let task = Task { [context] in
            let response = await context.requestAttention(request)
            if case .answered(let answer) = response, answer.buttonID == Self.jumpButtonID {
                self.jump(to: thread, saved: saved)
            }
            if self.notices[thread]?.id == id {
                self.notices[thread] = nil
            }
        }
        notices[thread] = (id, task)
        return task
    }

    /// Brings the thread's TUI terminal forward, or opens the notch when it is unknown or gone. The
    /// terminal it joined in comes first: another TUI may work in the same folder now.
    private func jump(to thread: String, saved: TerminalLocation?) {
        if let found = saved ?? terminal(threads[thread]), activator.activate(found) {
            return
        }
        context.expand()
    }

    private func icon(_ params: JSONValue) -> Image? {
        terminal(folder(params)).flatMap(ClaudeBridge.appIcon)
    }

    private func threadFolder(_ params: JSONValue) -> String? {
        params["threadId"]?.string.flatMap { threads[$0] }
    }

    /// Where the thread's TUI works, which finds its terminal.
    private func folder(_ params: JSONValue) -> String? {
        threadFolder(params) ?? params["cwd"]?.string
    }

    /// The last folder name of where the request acts: a command's own folder, otherwise the
    /// thread's working folder.
    private func projectName(_ params: JSONValue) -> String {
        guard let folder = params["cwd"]?.string ?? threadFolder(params), !folder.isEmpty else { return "Codex" }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    // MARK: What a request asks

    /// The command with everything else that changes what it may do. The notch offers 허용 only for a
    /// short command that asks for nothing more; a command run outside the thread's folder shows its
    /// folder there too, and goes to the full detail when both do not fit.
    static func commandDetail(_ params: JSONValue, threadFolder: String?) -> OperationDetail {
        var sections: [OperationDetail.Section] = []
        let command = params["command"]?.string
        let cwd = params["cwd"]?.string
        if let command { sections.append(.init(label: "명령", body: command)) }
        if let cwd { sections.append(.init(label: "폴더", body: cwd)) }
        if let reason = params["reason"]?.string { sections.append(.init(label: "이유", body: reason)) }
        var extra = false
        if let network = params["networkApprovalContext"], network != .null {
            sections.append(.init(label: "네트워크 접근", body: "\(network["protocol"]?.string ?? "") \(network["host"]?.string ?? "")"))
            extra = true
        }
        if let permissions = params["additionalPermissions"], permissions != .null {
            sections.append(.init(label: "추가 권한", body: Self.encode(permissions)))
            extra = true
        }
        guard let command else {
            return OperationDetail(tool: "명령", sections: [], notchText: nil, headline: "실행할 명령을 알 수 없어서 노치에서는 허용할 수 없어요. 터미널에서 확인해 주세요.")
        }
        let elsewhere = cwd.flatMap { $0 == threadFolder ? nil : $0 }
        let text = command + (elsewhere.map { "\n폴더: \($0)" } ?? "")
        let headline = if extra {
            "명령이 다른 권한도 함께 요청해요. 자세히 보기에서 전체 내용을 확인해 주세요."
        } else if OperationDetail.fitsNotch(command) {
            "명령을 실행할 폴더까지는 노치에 다 보이지 않아요. 자세히 보기에서 전체 내용을 확인해 주세요."
        } else {
            "명령이 길어서 노치에 다 보이지 않아요. 자세히 보기에서 전체 명령을 확인해 주세요."
        }
        return OperationDetail(
            tool: "명령",
            sections: sections,
            notchText: OperationDetail.fitsNotch(text) && !extra ? text : nil,
            headline: headline
        )
    }

    /// One section per changed file: its path and kind, then its diff. Nil unless every change has a
    /// path, a kind codex 0.153.4 sends and its diff, so an approval never covers a change the user
    /// could not read.
    static func sections(_ changes: [JSONValue]) -> [OperationDetail.Section]? {
        guard !changes.isEmpty else { return nil }
        var sections: [OperationDetail.Section] = []
        for change in changes {
            guard let path = change["path"]?.string, !path.isEmpty, let diff = change["diff"]?.string else { return nil }
            let kind: String
            switch change["kind"]?["type"]?.string {
            case "add": kind = "새 파일"
            case "delete": kind = "삭제"
            case "update": kind = change["kind"]?["move_path"]?.string.map { "\($0)(으)로 이동" } ?? "수정"
            default: return nil
            }
            sections.append(.init(label: "\(path) (\(kind))", body: diff))
        }
        return sections
    }
}

extension OperationDetail {
    init(tool: String, sections: [Section], notchText: String?, headline: String) {
        self.tool = tool
        self.sections = sections
        self.notchText = notchText
        self.headline = headline
    }
}

/// One `item/tool/requestUserInput` question.
struct CodexQuestion: Equatable {
    let id: String
    let header: String
    let text: String
    let options: [String]
    /// Free text is accepted besides the options.
    let isOther: Bool
    let isSecret: Bool

    var prompt: String { header.isEmpty ? text : "\(header) · \(text)" }
    var takesText: Bool { isOther || options.isEmpty }
    /// The question as the Agents screen's form shows it.
    var question: Question { Question(text: prompt, options: options, multiple: false, takesText: takesText) }

    static func parse(_ value: JSONValue?) -> [CodexQuestion]? {
        guard let items = value?.array, !items.isEmpty else { return nil }
        let questions = items.compactMap { item -> CodexQuestion? in
            guard let id = item["id"]?.string, let text = item["question"]?.string else { return nil }
            return CodexQuestion(
                id: id,
                header: item["header"]?.string ?? "",
                text: text,
                options: item["options"]?.array?.compactMap { $0["label"]?.string } ?? [],
                isOther: item["isOther"]?.bool ?? false,
                isSecret: item["isSecret"]?.bool ?? false
            )
        }
        return questions.count == items.count ? questions : nil
    }

    /// `{"<id>": {"answers": [...]}}`: the picked options, otherwise the typed text where the question
    /// takes text. Nil while some question has neither.
    static func answers(_ questions: [CodexQuestion], picked: [Int: [String]], typed: [Int: String]) -> JSONValue? {
        var answers: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            let text = typed[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let picks = picked[index], !picks.isEmpty {
                answers[question.id] = .object(["answers": .array(picks.map(JSONValue.string))])
            } else if !text.isEmpty, question.takesText {
                answers[question.id] = .object(["answers": .array([.string(text)])])
            } else {
                return nil
            }
        }
        return .object(answers)
    }
}
