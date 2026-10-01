import HookBridge
import NotchKit
import SwiftUI

/// Speaks codex's app-server protocol (JSON-RPC without a `jsonrpc` member, shapes from codex-cli
/// 0.153.4's `generate-json-schema`) for one connection at a time: initializes, subscribes to every
/// loaded thread and to each new one (`thread/started`), and turns the server's requests into notch
/// requests. Command and file-change approvals are answered `accept`, `acceptForSession` or
/// `decline`; questions are answered by question id. A request answered elsewhere
/// (`serverRequest/resolved`), one the user hands back to the terminal and one that times out leave
/// the notch unanswered, so the `codex` TUI keeps its own prompt. A finished turn glows with the
/// project name, and from there the user jumps to the TUI's terminal.
@MainActor
final class CodexBridge {
    nonisolated static let allowButtonID = "allow"
    nonisolated static let allowForSessionButtonID = "allow-session"
    nonisolated static let denyButtonID = "deny"
    nonisolated static let detailsButtonID = "details"
    nonisolated static let typeAnswersButtonID = "type-answers"
    nonisolated static let sendAnswersButtonID = "send-answers"
    nonisolated static let jumpButtonID = "jump"
    /// Codex's blue-gray.
    static let accent = Color(red: 0.45, green: 0.55, blue: 0.95)
    static let clientInfo: JSONValue = .object([
        "name": .string("notch-the-rock"),
        "title": .string("NotchTheRock"),
        "version": .string(AgentsPlugin.manifest.version),
    ])

    /// Requests shown in full; the plugin passes the screen its tab shows.
    let screen: AgentsScreenModel
    private let context: NotchContext
    private let activator: any TerminalActivating
    /// The terminal of the `codex` TUI working in a folder, looked up when it is needed.
    private let terminal: @MainActor (String?) -> TerminalLocation?
    private let wait: @MainActor () -> Duration
    /// Thread folders by thread id, kept across connections.
    private(set) var threads: [String: String] = [:]

    // One connection's state; `close()` clears it.
    private var send: (@MainActor (JSONValue) -> Void)?
    private var callCount = 0
    private var calls: [Int: Call] = [:]
    private var resumed: Set<String> = []
    /// The `changes` of each file-change item, from `item/started` and `item/fileChange/patchUpdated`.
    private var fileChanges: [String: [JSONValue]] = [:]
    /// Server requests waiting for the user, by request id.
    private var pending: [JSONValue: (number: Int, task: Task<Void, Never>)] = [:]
    private var pendingCount = 0
    private var notices: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var noticeCount = 0

    private enum Call {
        case initialize
        case list
        case resume(String)
    }

    init(
        context: NotchContext,
        activator: any TerminalActivating,
        screen: AgentsScreenModel = AgentsScreenModel(),
        terminal: @escaping @MainActor (String?) -> TerminalLocation?,
        wait: @escaping @MainActor () -> Duration = { .seconds(ApprovalWait.defaultSeconds) }
    ) {
        self.context = context
        self.activator = activator
        self.screen = screen
        self.terminal = terminal
        self.wait = wait
    }

    /// A new connection: `send` writes one message to it. Starts with `initialize`.
    func open(send: @escaping @MainActor (JSONValue) -> Void) {
        close()
        self.send = send
        call(.initialize, "initialize", .object([
            "clientInfo": Self.clientInfo,
            "capabilities": .object(["experimentalApi": .bool(true)]),
        ]))
    }

    /// The connection is gone: its requests can no longer be answered, so they leave the notch.
    func close() {
        send = nil
        calls.removeAll()
        callCount = 0
        resumed.removeAll()
        fileChanges.removeAll()
        for request in pending.values {
            request.task.cancel()
        }
        pending.removeAll()
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
        if let method = message["method"]?.string {
            let params = message["params"] ?? .null
            if let id = message["id"] {
                return request(id, method, params)
            }
            return notification(method, params)
        }
        if case .number(let number) = message["id"], let call = calls.removeValue(forKey: Int(number)) {
            if let error = message["error"] {
                context.log.error("codex app-server refused a request: \(Self.encode(error))")
                if case .resume(let thread) = call { resumed.remove(thread) }
                return nil
            }
            response(call, message["result"] ?? .null)
        }
        return nil
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
            send?(.object(["method": .string("initialized")]))
            call(.list, "thread/loaded/list", .object([:]))
        case .list:
            if let cursor = result["nextCursor"]?.string {
                call(.list, "thread/loaded/list", .object(["cursor": .string(cursor)]))
            }
            for thread in result["data"]?.array?.compactMap(\.string) ?? [] {
                resume(thread)
            }
        case .resume(let thread):
            if let cwd = result["thread"]?["cwd"]?.string ?? result["cwd"]?.string {
                threads[thread] = cwd
            }
        }
    }

    /// Subscribes to a thread's events and requests. Only the id is sent: any other member would
    /// change the settings of the TUI's live thread.
    private func resume(_ thread: String) {
        guard resumed.insert(thread).inserted else { return }
        call(.resume(thread), "thread/resume", .object(["threadId": .string(thread), "excludeTurns": .bool(true)]))
    }

    // MARK: Notifications

    private func notification(_ method: String, _ params: JSONValue) -> Task<Void, Never>? {
        switch method {
        case "thread/started":
            guard let thread = params["thread"], let id = thread["id"]?.string else { return nil }
            if let cwd = thread["cwd"]?.string { threads[id] = cwd }
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
        case "turn/completed":
            guard let thread = params["threadId"]?.string else { return nil }
            switch params["turn"]?["status"]?.string {
            case "completed": return notify(thread, message: "Codex가 작업을 마쳤어요.")
            case "failed": return notify(thread, message: "Codex 작업이 오류로 멈췄어요.")
            default: return nil
            }
        default:
            break
        }
        return nil
    }

    // MARK: Requests

    private func request(_ id: JSONValue, _ method: String, _ params: JSONValue) -> Task<Void, Never>? {
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
        let task = Task {
            let result = await ask()
            if !Task.isCancelled, let result {
                self.send?(.object(["id": id, "result": result]))
            }
            if self.pending[id]?.number == number {
                self.pending[id] = nil
            }
        }
        pending[id] = (number, task)
        return task
    }

    private func decideCommand(_ params: JSONValue) async -> String? {
        let detail = Self.commandDetail(params)
        let title = "\(projectName(params)) · \(params["kind"]?.string == "writeStdin" ? "터미널 입력" : "명령 실행")"
        let available = params["availableDecisions"]?.array?.compactMap(\.string)
        var buttons = [AttentionButton(id: Self.denyButtonID, title: "거부", role: .destructive)]
        if detail.notchText != nil {
            if available?.contains("acceptForSession") ?? true {
                buttons.append(AttentionButton(id: Self.allowForSessionButtonID, title: "이번 세션 동안 허용"))
            }
            buttons.append(AttentionButton(id: Self.allowButtonID, title: "허용", role: .primary))
        } else if !detail.sections.isEmpty {
            buttons.append(AttentionButton(id: Self.detailsButtonID, title: "자세히 보기", role: .primary))
        }
        return await decide(title: title, detail: detail, buttons: buttons, params: params)
    }

    private func decideFileChange(_ params: JSONValue) async -> String? {
        let title = "\(projectName(params)) · 파일 수정"
        var buttons = [AttentionButton(id: Self.denyButtonID, title: "거부", role: .destructive)]
        let detail: OperationDetail
        if let id = params["itemId"]?.string, let changes = fileChanges[id], case let changed = Self.sections(changes), !changed.isEmpty {
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
                headline: "바뀌는 내용을 알 수 없어서 노치에서는 허용할 수 없어요. 터미널에서 확인해 주세요."
            )
        }
        return await decide(title: title, detail: detail, buttons: buttons, params: params)
    }

    /// Asks in the notch and, for 자세히 보기, on the Agents screen. Nil leaves the request to the TUI.
    private func decide(title: String, detail: OperationDetail, buttons: [AttentionButton], params: JSONValue) async -> String? {
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
            switch await showOnScreen(title, .permission(detail), until: deadline) {
            case .allow: return "accept"
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

    private func showOnScreen(_ title: String, _ content: ScreenItem.Content, until deadline: ContinuousClock.Instant) async -> ScreenResponse {
        guard deadline > .now else { return .timedOut }
        context.expand()
        return await screen.show(title: title, content: content, until: deadline)
    }

    // MARK: Notices and the terminal

    private func notify(_ thread: String, message: String) -> Task<Void, Never> {
        notices[thread]?.task.cancel()
        noticeCount += 1
        let id = noticeCount
        let found = terminal(threads[thread])
        let request = AttentionRequest(
            title: projectName(.object(["threadId": .string(thread)])),
            message: message,
            accent: Self.accent,
            sourceIcon: found.flatMap(ClaudeBridge.appIcon),
            buttons: [AttentionButton(id: Self.jumpButtonID, title: found == nil ? "노치 열기" : "터미널로 이동", role: .primary)],
            timeout: ClaudeBridge.noticeTimeout
        )
        let task = Task { [context] in
            let response = await context.requestAttention(request)
            if case .answered(let answer) = response, answer.buttonID == Self.jumpButtonID {
                self.jump(to: thread)
            }
            if self.notices[thread]?.id == id {
                self.notices[thread] = nil
            }
        }
        notices[thread] = (id, task)
        return task
    }

    /// Brings the thread's TUI terminal forward, or opens the notch when it is unknown or gone.
    private func jump(to thread: String) {
        if let found = terminal(threads[thread]), activator.activate(found) {
            return
        }
        context.expand()
    }

    private func icon(_ params: JSONValue) -> Image? {
        terminal(folder(params)).flatMap(ClaudeBridge.appIcon)
    }

    private func folder(_ params: JSONValue) -> String? {
        params["threadId"]?.string.flatMap { threads[$0] } ?? params["cwd"]?.string
    }

    /// The last folder name of the thread's working folder.
    private func projectName(_ params: JSONValue) -> String {
        guard let folder = folder(params), !folder.isEmpty else { return "Codex" }
        return URL(fileURLWithPath: folder).lastPathComponent
    }

    // MARK: What a request asks

    /// The command with everything else that changes what it may do. The notch offers 허용 only for a
    /// short command that asks for nothing more.
    static func commandDetail(_ params: JSONValue) -> OperationDetail {
        var sections: [OperationDetail.Section] = []
        let command = params["command"]?.string
        if let command { sections.append(.init(label: "명령", body: command)) }
        if let cwd = params["cwd"]?.string { sections.append(.init(label: "폴더", body: cwd)) }
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
        guard command != nil else {
            return OperationDetail(tool: "명령", sections: [], notchText: nil, headline: "실행할 명령을 알 수 없어서 노치에서는 허용할 수 없어요. 터미널에서 확인해 주세요.")
        }
        let fits = command.map(OperationDetail.fitsNotch) ?? false
        return OperationDetail(
            tool: "명령",
            sections: sections,
            notchText: fits && !extra ? command : nil,
            headline: extra
                ? "명령이 다른 권한도 함께 요청해요. 자세히 보기에서 전체 내용을 확인해 주세요."
                : "명령이 길어서 노치에 다 보이지 않아요. 자세히 보기에서 전체 명령을 확인해 주세요."
        )
    }

    /// One section per changed file: its path and kind, then its diff.
    static func sections(_ changes: [JSONValue]) -> [OperationDetail.Section] {
        changes.compactMap { change in
            guard let path = change["path"]?.string else { return nil }
            let kind: String
            switch change["kind"]?["type"]?.string {
            case "add": kind = "새 파일"
            case "delete": kind = "삭제"
            default: kind = change["kind"]?["move_path"]?.string.map { "\($0)(으)로 이동" } ?? "수정"
            }
            return .init(label: "\(path) (\(kind))", body: change["diff"]?.string ?? "")
        }
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
    var question: Question { Question(text: prompt, options: options, multiple: false) }

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
