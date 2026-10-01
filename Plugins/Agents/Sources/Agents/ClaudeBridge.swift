import AppKit
import HookBridge
import NotchKit
import SwiftUI

/// What the plugin knows about one Claude Code session.
struct SessionRecord: Hashable {
    var terminal: TerminalLocation?
    var cwd: String?
}

/// Turns Claude Code hook messages into notch requests: records where each session runs, makes the
/// notch glow when a session finishes its turn or waits for input, and takes the user to the
/// session's terminal from there. Permission requests and AskUserQuestion are answered in the notch
/// within the configured wait, or handed back to the terminal.
@MainActor
final class ClaudeBridge {
    static let jumpButtonID = "jump"
    static let allowButtonID = "allow"
    static let denyButtonID = "deny"
    static let sendDenialButtonID = "send-denial"
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

    private let context: NotchContext
    private let activator: any TerminalActivating
    /// How long the notch waits for an answer before the request goes back to the terminal.
    private let wait: @MainActor () -> Duration
    private(set) var sessions: [String: SessionRecord] = [:]
    /// The notice each session shows; a newer one replaces it.
    private var notices: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var noticeCount = 0
    /// Requests whose hook waits for a decision, by number.
    private var decisions: [Int: Task<HookDecision?, Never>] = [:]
    private var decisionCount = 0

    init(context: NotchContext, activator: any TerminalActivating, wait: @escaping @MainActor () -> Duration = { .seconds(ApprovalWait.defaultSeconds) }) {
        self.context = context
        self.activator = activator
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
        let title = projectName(sessionID, message)
        switch message.event {
        case .permissionRequest:
            return await decidePermission(message, title: title)
        case .preToolUse:
            return await answerQuestions(message, title: title)
        case .sessionStart, .stop, .notification:
            return nil
        }
    }

    /// Handles one hook message. Returns the task that shows its notice, when it has one.
    @discardableResult
    func receive(_ message: HookMessage) -> Task<Void, Never>? {
        let payload = message.payload
        let sessionID = payload["session_id"]?.string ?? ""
        record(sessionID, message)
        let title = projectName(sessionID, message)
        switch message.event {
        case .sessionStart:
            return nil
        case .stop:
            return notify(sessionID, title: title, message: "Claude Code가 작업을 마쳤어요.")
        case .notification:
            if let type = payload["notification_type"]?.string, !Self.waitingNotificationTypes.contains(type) {
                return nil
            }
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
    }

    /// 허용 or 거부 for one tool call. 거부 then asks for a message to Claude in a text field.
    private func decidePermission(_ message: HookMessage, title: String) async -> HookDecision? {
        let tool = message.payload["tool_name"]?.string ?? "도구"
        // AskUserQuestion is answered through its PreToolUse hook.
        guard tool != "AskUserQuestion" else { return nil }
        let wait = wait()
        let deadline = ContinuousClock.now + wait
        let response = await context.requestAttention(AttentionRequest(
            title: "\(title) · \(tool)",
            message: Self.summary(of: message.payload["tool_input"]),
            accent: Self.accent,
            sourceIcon: terminalIcon(message),
            buttons: [
                AttentionButton(id: Self.denyButtonID, title: "거부", role: .destructive),
                AttentionButton(id: Self.allowButtonID, title: "허용", role: .primary),
            ],
            releaseTitle: Self.releaseTitle,
            timeout: wait
        ))
        guard case .answered(let answer) = response else { return nil }
        if answer.buttonID == Self.allowButtonID { return .allow }
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
        let text = written.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .deny(message: text.isEmpty ? Self.defaultDenial : text)
    }

    /// AskUserQuestion: each question's options (one or several), and a text field that answers the
    /// questions left without a picked option. A question left without either goes to the terminal.
    private func answerQuestions(_ message: HookMessage, title: String) async -> HookDecision? {
        guard message.payload["tool_name"]?.string == "AskUserQuestion",
              let items = message.payload["tool_input"]?["questions"]?.array, !items.isEmpty else { return nil }
        let questions = items.compactMap { item -> (text: String, options: [String], multiple: Bool)? in
            guard let text = item["question"]?.string else { return nil }
            let options = item["options"]?.array?.compactMap { $0["label"]?.string } ?? []
            return (text, options, item["multiSelect"]?.bool ?? false)
        }
        guard questions.count == items.count else { return nil }
        let response = await context.requestAttention(AttentionRequest(
            title: "\(title) · Claude의 질문",
            message: "",
            accent: Self.accent,
            sourceIcon: terminalIcon(message),
            choices: questions.enumerated().map { index, question in
                AttentionChoices(id: String(index), prompt: question.text, options: question.options, allowsMultiple: question.multiple)
            },
            textField: AttentionTextField(placeholder: "고르지 않은 질문에는 직접 답해요"),
            releaseTitle: Self.releaseTitle,
            timeout: wait()
        ))
        guard case .answered(let answer) = response else { return nil }
        let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var answers: [String: JSONValue] = [:]
        for (index, question) in questions.enumerated() {
            let picked = answer.choices[String(index)] ?? []
            if let first = picked.first {
                answers[question.text] = question.multiple ? .array(picked.map(JSONValue.string)) : .string(first)
            } else if !text.isEmpty {
                answers[question.text] = .string(text)
            } else {
                return nil
            }
        }
        return .answers(answers)
    }

    /// One line about what the tool will do: the Bash command, the file path, the URL…
    static func summary(of input: JSONValue?) -> String {
        let keys = ["command", "file_path", "notebook_path", "url", "query", "pattern", "path", "description", "prompt"]
        var text: String
        if let value = keys.lazy.compactMap({ input?[$0]?.string }).first {
            text = value
        } else if let input, let data = try? JSONEncoder().encode(input) {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
        text = text.split(whereSeparator: \.isNewline).joined(separator: " ⏎ ")
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
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
            sourceIcon: terminal.flatMap(Self.appIcon),
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
        sessions[sessionID] = record
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

    private static func appIcon(_ terminal: TerminalLocation) -> Image? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal.bundleID) else { return nil }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
