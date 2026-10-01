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
/// session's terminal from there.
@MainActor
final class ClaudeBridge {
    static let jumpButtonID = "jump"
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
    private(set) var sessions: [String: SessionRecord] = [:]
    /// The notice each session shows; a newer one replaces it.
    private var notices: [String: (id: Int, task: Task<Void, Never>)] = [:]
    private var noticeCount = 0

    init(context: NotchContext, activator: any TerminalActivating) {
        self.context = context
        self.activator = activator
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
        }
    }

    /// Withdraws every notice. Called when the plugin is turned off.
    func cancelAll() {
        for notice in notices.values {
            notice.task.cancel()
        }
        notices.removeAll()
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
