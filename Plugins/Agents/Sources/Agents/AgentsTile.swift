import NotchKit
import SwiftUI

/// The home tile; tapping it opens the Agents screen. It draws the session list the screen draws.
/// Wide: up to three sessions, those waiting for an approval or an answer first, then those at work,
/// then the idle ones, a line each with the agent's mark, the folder, the context use when known and
/// the state in its colour, and
/// how many more there are. Small: the marks of the agents with open sessions, how many are open and,
/// highlighted, how many wait for the user. Without sessions both marks are dimmed.
struct AgentsTile: View {
    static let wideCount = 3
    static let emptyTitle = "진행 중인 세션이 없어요"

    let sessions: AgentSessionList
    var logos: (any AgentLogoProviding)? = nil
    let size: TileSize

    /// The wide tile's rows: waiting for the user, then working, then idle; within each the most
    /// recently changed first, as the screen lists them.
    var rows: [AgentSession] {
        let ordered = sessions.sessions.sorted { a, b in
            (Self.rank(a.state), b.changed, b.id.id) < (Self.rank(b.state), a.changed, a.id.id)
        }
        return Array(ordered.prefix(Self.wideCount))
    }

    /// The open sessions the wide tile has no row for.
    var more: Int { max(0, count - Self.wideCount) }

    var count: Int { sessions.sessions.count }

    /// Sessions waiting for an approval or an answer.
    var waiting: Int {
        sessions.sessions.filter { Self.rank($0.state) == 0 }.count
    }

    /// The agents with open sessions, Claude first.
    var agents: [AgentKind] {
        [AgentKind.claude, .codex].filter { agent in sessions.sessions.contains { $0.agent == agent } }
    }

    private static func rank(_ state: AgentSessionState) -> Int {
        switch state {
        case .awaitingApproval, .awaitingAnswer: 0
        case .working: 1
        case .idle: 2
        }
    }

    var body: some View {
        switch size {
        case .small:
            small
        case .wide, .large:
            wide
        @unknown default:
            wide
        }
    }

    /// 170 pt wide; at most 69 pt tall: three rows of 16 pt and the "+N" line, 3 pt apart.
    private var wide: some View {
        let rows = rows
        return VStack(alignment: .leading, spacing: 3) {
            if rows.isEmpty {
                VStack(spacing: 6) {
                    marks([.claude, .codex], side: 18, dimmed: true)
                    Text(Self.emptyTitle)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 170)
            }
            ForEach(rows) { session in
                HStack(spacing: 6) {
                    mark(session.agent, side: 14, dimmed: false)
                    Text(session.folder)
                        .font(.system(size: 11, weight: .medium))
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if let percent = session.contextPercent {
                        ContextMeter(percent: percent)
                    }
                    Text(session.state.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(session.state.color)
                        .fixedSize()
                }
                .frame(height: 16)
            }
            if more > 0 {
                Text("+\(more)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(height: 12)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .frame(width: 170, alignment: .leading)
        .padding(10)
    }

    /// 70 pt wide: the marks, the number of sessions and the highlighted number waiting.
    private var small: some View {
        let agents = agents
        return VStack(spacing: 4) {
            marks(agents.isEmpty ? [.claude, .codex] : agents, side: 18, dimmed: agents.isEmpty)
            if count == 0 {
                Text("세션 없음")
                    .foregroundStyle(.secondary)
            } else {
                Text("세션 \(count)개")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                if waiting > 0 {
                    Text("응답 대기 \(waiting)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.orange.opacity(0.2), in: Capsule())
                } else {
                    Text("응답 대기 0")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .frame(width: 70)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func marks(_ agents: [AgentKind], side: CGFloat, dimmed: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(agents, id: \.self) { mark($0, side: side, dimmed: dimmed) }
        }
    }

    private func mark(_ agent: AgentKind, side: CGFloat, dimmed: Bool) -> some View {
        agent.alertIcon(logos)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: side, height: side)
            .opacity(dimmed ? 0.35 : 1)
            .accessibilityLabel(agent.name)
    }
}
