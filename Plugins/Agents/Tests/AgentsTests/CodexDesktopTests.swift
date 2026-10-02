import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// Codex desktop app threads on the shared app-server, closed sessions and the watcher's reading costs.
@MainActor
@Suite struct CodexDesktopTests {
    static let resumed = "019c0000-0000-7000-8000-00000000d101"
    static let started = "019c0000-0000-7000-8000-00000000d102"
    static let terminalThread = "019c0000-0000-7000-8000-00000000c103"
    let host = FakeHost()
    let activator = FakeActivator()
    let bridge: CodexBridge

    init() throws {
        let context = try makeContext(host: host, directory: try makeDirectory())
        bridge = CodexBridge(context: context, activator: activator, terminal: { _ in ghostty })
        bridge.open { _ in }
    }

    func row(_ id: String) -> AgentSession? {
        bridge.screen.sessions[AgentSession.Key(agent: .codex, id: id)]
    }

    /// A recorded message, moved to `thread`.
    func on(_ thread: String, _ fixture: String) throws -> JSONValue {
        try jsonValue(CodexBridge.encode(try codexFixture(fixture)).replacingOccurrences(of: CodexBridgeTests.thread1, with: thread))
    }

    static func started(_ id: String, cwd: String, source: String) -> String {
        #"{"method":"thread/started","params":{"thread":{"id":"\#(id)","cwd":"\#(cwd)","source":"\#(source)","status":{"type":"idle"}}}}"#
    }

    @Test func R56__desktop_threads_on_the_shared_app_server_alert_and_jump_to_the_codex_app() async throws {
        // One desktop thread listed and resumed, one started later, and a terminal's thread.
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try jsonValue(#"{"id":2,"result":{"data":["\#(Self.resumed)"],"nextCursor":null}}"#))
        bridge.receive(try jsonValue(#"{"id":3,"result":{"thread":{"id":"\#(Self.resumed)","cwd":"/Users/me/tide-pool","source":"vscode","status":{"type":"idle"}}}}"#))
        bridge.receive(try jsonValue(Self.started(Self.started, cwd: "/Users/me/rock-garden", source: "vscode")))
        bridge.receive(try jsonValue(Self.started(Self.terminalThread, cwd: "/Users/me/notch-the-rock", source: "cli")))
        #expect(row(Self.resumed)?.terminal == CodexRollouts.desktopApp)
        #expect(row(Self.started)?.terminal == CodexRollouts.desktopApp)
        #expect(row(Self.terminalThread)?.terminal == ghostty)

        // Approval and input requests: one each, and the rows wait.
        await bridge.receive(try on(Self.resumed, "commandApproval"))?.value
        #expect(host.requests.count == 1 && row(Self.resumed)?.state == .awaitingApproval)
        await bridge.receive(try on(Self.started, "userInput"))?.value
        #expect(host.requests.count == 2 && row(Self.started)?.state == .awaitingAnswer)

        // The thread closing alerts once; its jump brings the Codex app forward and folds the notch.
        host.responses = [.answered(AttentionAnswer(buttonID: CodexBridge.jumpButtonID, choices: [:], text: nil))]
        await bridge.receive(try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(Self.resumed)"}}"#))?.value
        #expect(host.requests.count == 3 && host.requests[2].message == "Codex 세션이 끝났어요.")
        #expect(host.requests[2].buttons.map(\.title) == ["Codex 앱으로 이동"])
        #expect(activator.activated == [CodexRollouts.desktopApp] && host.collapses == 1 && host.expansions == 0)
        #expect(bridge.receive(try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(Self.resumed)"}}"#)) == nil)

        // A finished turn of the other desktop thread alerts once with the same jump; the terminal's keeps its own.
        await bridge.receive(try on(Self.started, "turnCompleted"))?.value
        #expect(host.requests.count == 4 && host.requests[3].buttons.map(\.title) == ["Codex 앱으로 이동"])
        await bridge.receive(try on(Self.terminalThread, "turnCompleted"))?.value
        #expect(host.requests.count == 5 && host.requests[4].buttons.map(\.title) == ["터미널로 이동"])
    }

    @Test func R56__settings_say_what_rollouts_lack_and_how_to_turn_on_the_shared_app_server() async throws {
        let note = AgentsSettingsView.rolloutNote
        #expect(note.contains("승인·입력 대기 알림") && note.contains("세션 종료 알림"))
        #expect(note.contains("CODEX_APP_SERVER_USE_LOCAL_DAEMON=1"))
        let directory = try makeDirectory()
        let defaults = try #require(UserDefaults(suiteName: isolatedDefaultsSuite(in: directory)))
        let codex = CodexModel(defaults: defaults, executable: URL(fileURLWithPath: "/opt/homebrew/bin/codex"), readVersion: { _ in "0.153.4" }, start: {}, stop: {})
        await codex.checkVersion()
        let hooks = ClaudeHooksModel(installer: HookInstaller(
            settingsURL: directory.appendingPathComponent("settings.json"),
            recordURL: directory.appendingPathComponent("record.json"),
            entries: HookEntry.claude(helper: directory.appendingPathComponent("notch-hook"))
        ))
        try capture(Form { AgentsSettingsView(model: hooks, codex: codex, defaults: defaults) }.formStyle(.grouped).frame(width: 520), named: "R56-render-settings-T160")
    }

    @Test func R55__turn_dedupe_forgets_only_its_oldest_turn() {
        #expect((0..<1024).allSatisfy { bridge.claimTurnAlert("thread", turn: "\($0)") })
        // Full: a turn seen already still counts as seen, the newest and the oldest alike.
        #expect(!bridge.claimTurnAlert("thread", turn: "1023"))
        #expect(!bridge.claimTurnAlert("thread", turn: "0"))
        // One more forgets the oldest only.
        #expect(bridge.claimTurnAlert("thread", turn: "1024"))
        #expect(!bridge.claimTurnAlert("thread", turn: "1"))
        #expect(bridge.claimTurnAlert("thread", turn: "0"))
    }
}

extension CodexRolloutTests {
    @Test func R55__a_session_the_bridge_closed_stays_closed_after_a_late_rollout() async throws {
        await scan()
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        bridge.receive(try codexFixture("resumeResponse"))
        let followed = CodexBridgeTests.thread1
        let turn = "019a0000-0000-7000-8000-0000000000a1"
        try tree.write(followed, [RolloutTree.meta(followed, cwd: "/Users/me/notch-the-rock", originator: "codex_cli_rs", source: #""cli""#), RolloutTree.event("task_started", turn: turn)])
        await scan()
        // The bridge sees the turn end and the thread close before the next pass.
        await bridge.receive(try codexFixture("turnCompleted"))?.value
        await bridge.receive(try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(followed)"}}"#))?.value
        #expect(host.requests.count == 2 && session(followed) == nil)

        // The rollout's record of that turn ending is read late: no row and no second alert.
        try tree.append(followed, RolloutTree.event("task_complete", turn: turn) + "\n")
        await scan()
        #expect(host.requests.count == 2 && session(followed) == nil)
        // Nor does anything later in the rollout bring back what the bridge closed.
        try tree.append(followed, [RolloutTree.event("task_started", turn: "t2"), ContextTests.tokenCount(last: 50000, total: 50000, window: "258400")].map { $0 + "\n" }.joined())
        await scan()
        #expect(host.requests.count == 2 && session(followed) == nil)
    }

    @Test func R55__an_ended_rollout_session_comes_back_only_with_a_new_turn() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        try tree.append(Self.desktop, [RolloutTree.event("task_complete", turn: "t1"), #"{"type":"event_msg","payload":{"type":"shutdown_complete"}}"#, ContextTests.tokenCount(last: 50000, total: 50000, window: "258400")].map { $0 + "\n" }.joined())
        await scan()
        #expect(host.requests.count == 1 && session(Self.desktop) == nil)
        // Resumed in the app: a new turn brings the row back.
        try tree.append(Self.desktop, RolloutTree.event("task_started", turn: "t2") + "\n")
        await scan()
        #expect(session(Self.desktop)?.state == .working)
    }

    @Test func R55__fast_passes_leave_old_folders_to_the_discovery_once_a_minute() async throws {
        let old = tree.root.appendingPathComponent("2025/01/15")
        let resumed = "019b0000-0000-7000-8000-00000000d201"
        try tree.write(resumed, [RolloutTree.meta(resumed, cwd: "/Users/me/old-shell"), RolloutTree.event("task_started", turn: "t1")], modified: Date(timeIntervalSinceNow: -10 * 3600), in: old)
        await scan()
        #expect(list.sessions.isEmpty)
        // Written to again: a pass two seconds later does not look in the old folder.
        try tree.append(resumed, RolloutTree.event("task_complete", turn: "t1") + "\n", in: old)
        clock.offset += 2
        await scan()
        #expect(host.requests.isEmpty && list.sessions.isEmpty)
        // The discovery a minute on finds it, and from then on it is followed on every pass.
        clock.offset += 60
        await scan()
        #expect(host.requests.count == 1 && session(resumed)?.folder == "old-shell" && session(resumed)?.state == .idle)
        try tree.append(resumed, [RolloutTree.event("task_started", turn: "t2"), RolloutTree.event("task_complete", turn: "t2")].map { $0 + "\n" }.joined(), in: old)
        clock.offset += 2
        await scan()
        #expect(host.requests.count == 2)
    }

    @Test func R55__lines_longer_than_a_read_and_long_files_on_restart() async throws {
        await scan()
        try tree.write(Self.desktop, [RolloutTree.meta(Self.desktop, cwd: "/Users/me/tide-pool"), RolloutTree.event("task_started", turn: "t1")])
        await scan()
        // A line longer than one read, then the turn's end.
        let filler = #"{"type":"response_item","payload":{"type":"message","text":""# + String(repeating: "x", count: 300 << 10) + #""}}"#
        try tree.append(Self.desktop, [filler, RolloutTree.event("task_complete", turn: "t1")].map { $0 + "\n" }.joined())
        await scan()
        #expect(host.requests.count == 1 && session(Self.desktop)?.state == .idle)

        // After a restart the file is indexed from its tail: the latest state and context use, no alert.
        try tree.append(Self.desktop, [filler, filler, RolloutTree.event("task_started", turn: "t2"), ContextTests.tokenCount(last: 50000, total: 50000, window: "258400"), filler].map { $0 + "\n" }.joined())
        watcher.stop()
        #expect(session(Self.desktop) == nil)
        await scan()
        #expect(host.requests.count == 1)
        #expect(session(Self.desktop)?.state == .working && session(Self.desktop)?.folder == "tide-pool" && session(Self.desktop)?.contextPercent == 15)
    }
}

extension ContextTests {
    @Test func R49__claudes_window_counts_only_when_it_is_certain() {
        func percent(_ model: String, _ used: Int) -> Int? {
            ContextUsage.claude(tail: Transcript.data([Transcript.assistant(model, input: used, creation: 0, read: 0)]))
        }
        // Never 1M: claude-3 models, Opus 4 to 4.5 and Haiku 4.5, dated or not.
        #expect(percent("claude-opus-4-5-20251101", 84000) == 42)
        #expect(percent("claude-opus-4-20250514", 84000) == 42)
        #expect(percent("claude-haiku-4-5-20251001", 84000) == 42)
        #expect(percent("claude-3-5-haiku-20241022", 84000) == 42)
        // Always 1M, or opted in by name.
        #expect(percent("claude-opus-4-8", 120000) == 12)
        #expect(percent("claude-opus-5-5", 120000) == 12)
        #expect(percent("claude-sonnet-4-6[1m]", 120000) == 12)
        // Either window, and nothing in the transcript tells which: no percent until it is past 200k.
        #expect(percent("claude-sonnet-4-5-20250929", 84000) == nil)
        #expect(percent("claude-sonnet-4-20250514", 84000) == nil)
        #expect(percent("claude-opus-4-6", 84000) == nil)
        #expect(percent("claude-opus-4-6", 300000) == 30)
        // A model Claude Code's catalog does not know.
        #expect(percent("claude-nova-9", 84000) == nil)
    }

    @Test func R49__token_counts_must_be_whole_non_negative_numbers() {
        func claude(_ input: String, _ read: String = "0") -> Int? {
            let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":0,"cache_read_input_tokens":\#(read),"output_tokens":1}}}"#
            return ContextUsage.claude(tail: Data((line + "\n").utf8))
        }
        #expect(claude("120000") == 12)
        #expect(claude("1e100") == nil)
        #expect(claude("-5", "100000") == nil)
        #expect(claude("1.5", "100000") == nil)
        #expect(claude("9e18", "9e18") == nil)
        #expect(ContextUsage.codex(lastTotal: .number(50000), window: .number(258400)) == 15)
        #expect(ContextUsage.codex(lastTotal: .number(1e100), window: .number(258400)) == nil)
        #expect(ContextUsage.codex(lastTotal: .number(50000), window: .number(-1)) == nil)
        #expect(ContextUsage.codex(lastTotal: .number(50000), window: .number(.infinity)) == nil)
        #expect(RolloutReader.record(Data(Self.tokenCount(last: 50000, total: 50000, window: "1e300").utf8)) == nil)
    }
}
