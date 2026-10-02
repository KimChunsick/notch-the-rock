import Darwin
import Foundation
import HookBridge
import Observation
import SwiftUI

/// The coding agents whose sessions the Agents screen lists.
enum AgentKind: Hashable, Sendable {
    case claude
    case codex

    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    /// Shown with the name when the agent's own mark is not available.
    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "terminal"
        }
    }
}

enum AgentSessionState: Hashable, Sendable {
    case working
    case awaitingApproval
    case awaitingAnswer
    case idle

    var title: String {
        switch self {
        case .working: "작업 중"
        case .awaitingApproval: "승인 대기"
        case .awaitingAnswer: "질문 대기"
        case .idle: "대기 중"
        }
    }

    var color: Color {
        switch self {
        case .working: .green
        case .awaitingApproval: .orange
        case .awaitingAnswer: .blue
        case .idle: .gray
        }
    }
}

/// One open session of a coding agent.
struct AgentSession: Identifiable, Hashable {
    struct Key: Hashable {
        let agent: AgentKind
        /// The agent's own session or thread id.
        let id: String
    }

    let id: Key
    /// The last folder name of the session's working folder.
    var folder: String
    var state: AgentSessionState
    /// When the session's last event arrived.
    var changed: Date
    var terminal: TerminalLocation?
    /// The agent's process, when known; the session is over once it is gone.
    var pid: pid_t?
    /// How full the session's context window is, in percent; nil when unknown.
    var contextPercent: Int?

    var agent: AgentKind { id.agent }

    /// How long ago the session last changed, as the row shows it.
    static func elapsed(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분" }
        if minutes < 24 * 60 { return "\(minutes / 60)시간" }
        return "\(minutes / (24 * 60))일"
    }
}

/// The sessions the Agents screen lists, fed by the Claude Code hooks and the codex bridge. A
/// session joins on its first event (one that started before the app joins on its next one) and
/// leaves when it ends or when its process is gone; one whose process is not known leaves when it
/// stays silent for `silenceLimit`. The bridges keep what a session's end needs (its alert, its
/// terminal) themselves, so a row that left the list still ends once.
@MainActor
@Observable
final class AgentSessionList {
    static let silenceLimit: TimeInterval = 12 * 60 * 60
    /// How often `prune` runs while the plugin is active.
    static let pruneInterval: Duration = .seconds(10)

    private var byKey: [AgentSession.Key: AgentSession] = [:]
    @ObservationIgnored var now: () -> Date
    @ObservationIgnored var isAlive: (pid_t) -> Bool

    init(now: @escaping () -> Date = { .now }, isAlive: @escaping (pid_t) -> Bool = AgentSessionList.processExists) {
        self.now = now
        self.isAlive = isAlive
    }

    /// Most recently changed first.
    var sessions: [AgentSession] {
        byKey.values.sorted { ($0.changed, $0.id.id) > ($1.changed, $1.id.id) }
    }

    subscript(key: AgentSession.Key) -> AgentSession? { byKey[key] }

    /// Records an event of `key`'s session. A nil `state`, `terminal` or `pid` keeps what the list
    /// knows; a session seen for the first time without a state is idle. `changed` is when the event
    /// happened, when that was not just now (a rollout indexed at launch).
    func update(_ key: AgentSession.Key, folder: String, state: AgentSessionState?, terminal: TerminalLocation? = nil, pid: pid_t? = nil, changed: Date? = nil) {
        let changed = changed ?? now()
        var session = byKey[key] ?? AgentSession(id: key, folder: folder, state: state ?? .idle, changed: changed)
        session.folder = folder
        session.state = state ?? session.state
        session.changed = changed
        session.terminal = terminal ?? session.terminal
        session.pid = pid ?? session.pid
        byKey[key] = session
    }

    /// A request of `key`'s session was answered: it goes back to work, or shows `waiting` while
    /// another of its requests still waits, unless another event moved it on meanwhile.
    func answered(_ key: AgentSession.Key, waiting: AgentSessionState? = nil) {
        guard let state = byKey[key]?.state, state == .awaitingApproval || state == .awaitingAnswer else { return }
        byKey[key]?.state = waiting ?? .working
        byKey[key]?.changed = now()
    }

    /// Sets how full the context window of `key`'s session is. Not an event: the row keeps its place
    /// and its time, and a session not on the list stays off it.
    func setContext(_ key: AgentSession.Key, _ percent: Int?) {
        guard byKey[key] != nil else { return }
        byKey[key]?.contextPercent = percent
    }

    func remove(_ key: AgentSession.Key) {
        byKey[key] = nil
    }

    func removeAll(_ agent: AgentKind? = nil) {
        byKey = byKey.filter { agent != nil && $0.key.agent != agent }
    }

    /// Drops the sessions whose process is gone, and those without a known process that stayed
    /// silent for longer than `silenceLimit`. A process that still runs keeps its session.
    func prune() {
        let now = now()
        byKey = byKey.filter { _, session in
            if let pid = session.pid { return isAlive(pid) }
            return now.timeIntervalSince(session.changed) <= Self.silenceLimit
        }
    }

    /// False only when no process has the id `pid`; one of another user still counts.
    nonisolated static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }
}
