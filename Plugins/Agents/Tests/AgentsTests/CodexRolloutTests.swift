import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// A made-up `$CODEX_HOME/sessions` tree in a temporary folder.
struct RolloutTree {
    let root: URL

    init() throws {
        root = try makeDirectory("agents-rollouts").appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    }

    var day: URL { root.appendingPathComponent("2026/10/02") }

    func url(_ id: String) -> URL { day.appendingPathComponent("rollout-2026-10-02T09-00-00-\(id).jsonl") }

    func write(_ id: String, _ lines: [String], modified: Date? = nil) throws {
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: url(id))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url(id).path)
        }
    }

    func append(_ id: String, _ text: String) throws {
        let handle = try FileHandle(forWritingTo: url(id))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }

    static func meta(_ id: String, cwd: String, originator: String = "Codex Desktop", source: String = #""vscode""#, extra: String = "") -> String {
        #"{"timestamp":"2026-10-02T09:00:00.000Z","type":"session_meta","payload":{"id":"\#(id)","timestamp":"2026-10-02T09:00:00.000Z","cwd":"\#(cwd)","originator":"\#(originator)","cli_version":"0.153.4","source":\#(source)\#(extra)}}"#
    }

    static func event(_ type: String, turn: String) -> String {
        #"{"timestamp":"2026-10-02T09:01:00.000Z","type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turn)"}}"#
    }
}

@MainActor
@Suite struct CodexRolloutTests {
    static let desktop = "019b0000-0000-7000-8000-00000000d001"
    let host = FakeHost()
    let activator = FakeActivator()
    let outbox = Outbox()
    let tree: RolloutTree
    let bridge: CodexBridge
    let watcher: CodexRollouts

    init() throws {
        tree = try RolloutTree()
        let context = try makeContext(host: host, directory: try makeDirectory())
        let terminals = ["/Users/me/notch-the-rock": ghostty, "/Users/me/rock-garden": ghostty]
        let lookup: @MainActor (String?) -> TerminalLocation? = { cwd in cwd.flatMap { terminals[$0] } }
        bridge = CodexBridge(context: context, activator: activator, terminal: lookup)
        watcher = CodexRollouts(root: tree.root, context: context, bridge: bridge, activator: activator, terminal: lookup)
        bridge.open { [outbox] in outbox.messages.append($0) }
    }

    var list: AgentSessionList { bridge.screen.sessions }

    func session(_ id: String) -> AgentSession? {
        list[AgentSession.Key(agent: .codex, id: id)]
    }

    /// One pass, waiting for the alerts it raised to be answered.
    func scan() async {
        for task in await watcher.scan() { await task.value }
    }

    @Test func R52__a_desktop_session_lists_and_alerts_once_per_finished_turn() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        let row = try #require(session(Self.desktop))
        #expect(row.folder == "tide-pool" && row.state == .working && row.terminal == CodexRollouts.desktopApp)

        try tree.append(Self.desktop, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        #expect(session(Self.desktop)?.state == .idle)
        #expect(host.requests.count == 1)
        let alert = try #require(host.requests.first)
        #expect(alert.title == "tide-pool" && alert.message == "Codex가 작업을 마쳤어요.")
        #expect(alert.buttons.map(\.title) == ["Codex 앱으로 이동"] && alert.timeout == .seconds(5))

        // Nothing new: no second alert. The next turn alerts once more.
        await scan()
        #expect(host.requests.count == 1)
        try tree.append(Self.desktop, RolloutTree.event("task_started", turn: "t2") + "\n")
        await scan()
        #expect(session(Self.desktop)?.state == .working)
        try tree.append(Self.desktop, RolloutTree.event("task_complete", turn: "t2") + "\n")
        await scan()
        #expect(host.requests.count == 2 && session(Self.desktop)?.state == .idle)

        // A stopped turn goes back to waiting without an alert.
        try tree.append(Self.desktop, [RolloutTree.event("task_started", turn: "t3"), RolloutTree.event("turn_aborted", turn: "t3")].map { $0 + "\n" }.joined())
        await scan()
        #expect(host.requests.count == 2 && session(Self.desktop)?.state == .idle)
    }

    @Test func R40__the_desktop_alert_jumps_to_the_desktop_app_and_folds_the_notch() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        host.responses = [.answered(AttentionAnswer(buttonID: CodexBridge.jumpButtonID, choices: [:], text: nil))]
        try tree.append(Self.desktop, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        #expect(activator.activated == [CodexRollouts.desktopApp])
        #expect(CodexRollouts.desktopApp.bundleID == "com.openai.codex" && host.collapses == 1 && host.expansions == 0)
    }

    @Test func R52__a_partial_line_waits_until_it_is_complete() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        let line = RolloutTree.event("task_complete", turn: "t1")
        let cut = line.index(line.startIndex, offsetBy: 30)
        try tree.append(Self.desktop, String(line[..<cut]))
        await scan()
        #expect(session(Self.desktop)?.state == .working && host.requests.isEmpty)
        try tree.append(Self.desktop, String(line[cut...]) + "\n")
        await scan()
        #expect(session(Self.desktop)?.state == .idle && host.requests.count == 1)
    }

    @Test func R52__a_restart_indexes_the_history_without_alerts() async throws {
        let hourAgo = Date(timeIntervalSinceNow: -3600).rounded
        let finished = "019b0000-0000-7000-8000-00000000d002"
        let old = "019b0000-0000-7000-8000-00000000d003"
        let ended = "019b0000-0000-7000-8000-00000000d004"
        try tree.write(finished, [RolloutTree.meta(finished, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1"), RolloutTree.event("task_complete", turn: "t1")], modified: hourAgo)
        try tree.write(old, [RolloutTree.meta(old, cwd: "/Users/me/old-shell"), RolloutTree.event("task_started", turn: "t1")], modified: Date(timeIntervalSinceNow: -10 * 3600))
        try tree.write(ended, [RolloutTree.meta(ended, cwd: "/Users/me/done"), RolloutTree.event("task_complete", turn: "t1"), #"{"type":"event_msg","payload":{"type":"shutdown_complete"}}"#], modified: hourAgo)
        await scan()
        #expect(host.requests.isEmpty)
        #expect(list.sessions.map(\.id.id) == [finished])
        #expect(session(finished)?.state == .idle && session(finished)?.changed == hourAgo)

        // Followed from where the index left off: only what comes next alerts, the old file's included.
        try tree.append(finished, [RolloutTree.event("task_started", turn: "t2"), RolloutTree.event("task_complete", turn: "t2")].map { $0 + "\n" }.joined())
        try tree.append(old, RolloutTree.event("task_complete", turn: "t1") + "\n")
        await scan()
        #expect(Set(host.requests.map(\.title)) == ["tide-pool", "old-shell"] && host.requests.count == 2)
        #expect(session(old)?.folder == "old-shell" && session(old)?.state == .idle)
    }

    @Test func R52__a_thread_the_bridge_follows_alerts_once() async throws {
        await scan()
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        bridge.receive(try codexFixture("resumeResponse"))
        let followed = CodexBridgeTests.thread1
        let turn = "019a0000-0000-7000-8000-0000000000a1"
        try tree.write(followed, [RolloutTree.meta(followed, cwd: "/Users/me/notch-the-rock", originator: "codex_cli_rs", source: #""cli""#), RolloutTree.event("task_complete", turn: turn)])
        await scan()
        #expect(host.requests.isEmpty)
        await bridge.receive(try codexFixture("turnCompleted"))?.value
        #expect(host.requests.count == 1)

        // Seen in the rollout first, then by the bridge: the bridge's alert for that turn does not come.
        let other = "019a0000-0000-7000-8000-000000000005"
        try tree.write(other, [RolloutTree.meta(other, cwd: "/Users/me/rock-garden", originator: "codex_cli_rs", source: #""cli""#), RolloutTree.event("task_complete", turn: "turn-5")])
        await scan()
        #expect(host.requests.count == 2 && session(other)?.terminal == ghostty)
        bridge.receive(try jsonValue(#"{"method":"thread/started","params":{"thread":{"id":"\#(other)","cwd":"/Users/me/rock-garden"}}}"#))
        let late = bridge.receive(try jsonValue(#"{"method":"turn/completed","params":{"threadId":"\#(other)","turn":{"id":"turn-5","items":[],"status":"completed"}}}"#))
        #expect(late == nil && host.requests.count == 2)

        // The bridge's connection going away drops its own rows only.
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool")])
        await scan()
        bridge.close()
        #expect(list.sessions.map(\.id.id) == [Self.desktop])
    }

    @Test func R52__exec_and_subagent_sessions_are_ignored() async throws {
        await scan()
        let exec = "019b0000-0000-7000-8000-00000000e001"
        let subagent = "019b0000-0000-7000-8000-00000000e002"
        try tree.write(exec, [RolloutTree.meta(exec, cwd: "/Users/me/tide-pool", source: #""exec""#), RolloutTree.event("task_started", turn: "t1"), RolloutTree.event("task_complete", turn: "t1")])
        try tree.write(subagent, [
            RolloutTree.meta(subagent, cwd: "/Users/me/tide-pool", source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(Self.desktop)","depth":1}}}"#, extra: #","parent_thread_id":"\#(Self.desktop)""#),
            RolloutTree.event("task_started", turn: "t1"), RolloutTree.event("task_complete", turn: "t1"),
        ])
        await scan()
        #expect(list.sessions.isEmpty && host.requests.isEmpty)
    }
}

extension Date {
    /// Whole seconds, as a file's modification date keeps them.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded()) }
}
