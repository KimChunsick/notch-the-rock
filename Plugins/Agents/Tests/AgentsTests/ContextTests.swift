import AppKit
import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// A made-up Claude Code transcript: lines as Claude Code appends them.
enum Transcript {
    static func assistant(_ model: String, input: Int, creation: Int, read: Int) -> String {
        #"{"type":"assistant","sessionId":"s1","message":{"model":"\#(model)","role":"assistant","content":[],"usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(creation),"cache_read_input_tokens":\#(read),"output_tokens":500}}}"#
    }

    static let user = #"{"type":"user","sessionId":"s1","message":{"role":"user","content":"run the tests"}}"#
    static let synthetic = assistant("<synthetic>", input: 0, creation: 0, read: 0)

    static func data(_ lines: [String]) -> Data { Data(lines.map { $0 + "\n" }.joined().utf8) }
}

@MainActor
@Suite struct ContextTests {
    let host = FakeHost()
    let world = SessionWorld()

    static func tokenCount(last: Int, total: Int, window: String) -> String {
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\#(total)},"last_token_usage":{"total_tokens":\#(last)},"model_context_window":\#(window)},"rate_limits":null}}"#
    }

    @Test func R49__claude_transcript_tail_gives_the_used_share_of_the_models_window() {
        // 1 000 + 2 000 + 81 000 of a model that never runs with 1M; the synthetic message after it has no usage.
        let standard = Transcript.data([Transcript.user, Transcript.assistant("claude-opus-4-5-20251101", input: 1000, creation: 2000, read: 81000), Transcript.synthetic])
        #expect(ContextUsage.claude(tail: standard) == 42)
        // A model whose window is 1M by default.
        let long = Transcript.data([Transcript.assistant("claude-opus-4-8", input: 5000, creation: 10000, read: 105000)])
        #expect(ContextUsage.claude(tail: long) == 12)
        // A model that may run with 1M, past 200k, runs with it; the latest message counts, not the first.
        let past = Transcript.data([Transcript.assistant("claude-sonnet-4-5", input: 1, creation: 1, read: 1), Transcript.assistant("claude-sonnet-4-5", input: 0, creation: 0, read: 300000)])
        #expect(ContextUsage.claude(tail: past) == 30)
        // A tail cut mid-line, and no assistant message with usage: unknown.
        #expect(ContextUsage.claude(tail: Data("e\":1}}}\n".utf8) + Transcript.data([Transcript.user, Transcript.synthetic])) == nil)
    }

    @Test func R49__codex_usage_matches_codexs_own_context_left() {
        // codex: remaining = round((window − 12 000 − max(0, last − 12 000)) / (window − 12 000) × 100).
        #expect(ContextUsage.codexPercent(lastTotal: 50000, window: 258400) == 15)
        #expect(ContextUsage.codexPercent(lastTotal: 8000, window: 258400) == 0)
        #expect(ContextUsage.codexPercent(lastTotal: 258400, window: 258400) == 100)
        let record = RolloutReader.record(Data(Self.tokenCount(last: 50000, total: 900000, window: "258400").utf8))
        #expect(record == .context(15))
        #expect(RolloutReader.record(Data(#"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#.utf8)) == nil)
    }

    @Test func R49__a_claude_hook_reads_the_transcript_into_the_row() async throws {
        let directory = try makeDirectory()
        let transcript = directory.appendingPathComponent("s1.jsonl")
        try Transcript.data([Transcript.user, Transcript.assistant("claude-opus-4-8", input: 5000, creation: 10000, read: 105000)]).write(to: transcript)
        let bridge = ClaudeBridge(context: try makeContext(host: host, directory: directory), activator: FakeActivator())
        world.attach(to: bridge.screen.sessions)
        let key = AgentSession.Key(agent: .claude, id: "s1")
        let payload = #"{"session_id":"s1","cwd":"/Users/me/work/rock-garden","hook_event_name":"Stop","transcript_path":"\#(transcript.path)"}"#
        bridge.receive(HookMessage(event: .stop, payload: try json(payload), context: HookContext(terminal: ghostty, projectDir: nil, claudePID: 4242)))
        await bridge.refreshContext("s1")?.value
        #expect(bridge.screen.sessions[key]?.contextPercent == 12)
        // Without a transcript the row has no percent.
        let other = #"{"session_id":"s2","cwd":"/Users/me/work/tide-pool","hook_event_name":"Stop"}"#
        bridge.receive(HookMessage(event: .stop, payload: try json(other), context: HookContext(terminal: ghostty, projectDir: nil, claudePID: 4242)))
        #expect(bridge.refreshContext("s2") == nil)
        #expect(bridge.screen.sessions[AgentSession.Key(agent: .claude, id: "s2")]?.contextPercent == nil)
    }

    @Test func R49__codex_rows_take_the_bridges_usage_or_the_rollouts() async throws {
        let tree = try RolloutTree()
        let context = try makeContext(host: host, directory: try makeDirectory())
        let bridge = CodexBridge(context: context, activator: FakeActivator(), terminal: { _ in nil })
        let watcher = CodexRollouts(
            root: tree.root, context: context, bridge: bridge, activator: FakeActivator(), terminal: { _ in nil },
            processes: FakeCodexProcesses(tree: tree).snapshot
        )
        bridge.open { _ in }
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        bridge.receive(try codexFixture("resumeResponse"))
        let followed = AgentSession.Key(agent: .codex, id: CodexBridgeTests.thread1)
        let usage = #"{"method":"thread/tokenUsage/updated","params":{"threadId":"\#(followed.id)","turnId":"t1","tokenUsage":{"total":{"totalTokens":900000},"last":{"totalTokens":50000},"modelContextWindow":WINDOW}}}"#
        bridge.receive(try jsonValue(usage.replacingOccurrences(of: "WINDOW", with: "258400")))
        #expect(bridge.screen.sessions[followed]?.contextPercent == 15)
        bridge.receive(try jsonValue(usage.replacingOccurrences(of: "WINDOW", with: "null")))
        #expect(bridge.screen.sessions[followed]?.contextPercent == nil)

        let desktop = CodexRolloutTests.desktop
        await watcher.scan()
        try tree.write(desktop, [RolloutTree.meta(desktop, cwd: "/Users/me/tide-pool"), Self.tokenCount(last: 230000, total: 900000, window: "258400")])
        await watcher.scan()
        let row = AgentSession.Key(agent: .codex, id: desktop)
        #expect(bridge.screen.sessions[row]?.contextPercent == axisPercent(230000))
        // A token count without usage keeps what the row shows.
        try tree.append(desktop, #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"# + "\n")
        await watcher.scan()
        #expect(bridge.screen.sessions[row]?.contextPercent == axisPercent(230000))
    }

    func axisPercent(_ last: Int) -> Int { ContextUsage.codexPercent(lastTotal: last, window: 258400) }

    @Test func R33__rows_and_the_wide_tile_show_the_percent_at_the_same_height() throws {
        let list = AgentSessionList()
        world.attach(to: list)
        let logos = FakeLogos()
        logos.images[.claude] = solidLogo(.black, template: true)
        logos.images[.codex] = solidLogo(AlertTests.magenta, template: false)
        let claude = AgentSession.Key(agent: .claude, id: "c1"), codex = AgentSession.Key(agent: .codex, id: "x1"), unknown = AgentSession.Key(agent: .claude, id: "c2")
        list.update(unknown, folder: "rock-garden", state: .idle, terminal: ghostty)
        world.now += 1
        list.update(codex, folder: "notch-the-rock", state: .idle, terminal: ghostty)
        list.setContext(codex, 91)
        world.now += 1
        list.update(claude, folder: "tide-pool", state: .working, terminal: ghostty)
        list.setContext(claude, 42)
        #expect(list.sessions.map(\.contextPercent) == [42, 91, nil])

        func row(_ session: AgentSession) -> AgentSessionRow {
            AgentSessionRow(session: session, logo: logos.logo(for: session.agent), open: { _ in })
        }
        let heights = list.sessions.map { NSHostingView(rootView: row($0)).fittingSize.height }
        #expect(Set(heights).count == 1, "\(heights)")
        // Warm above 80%: only the 91% row has orange in it.
        let warm = try share(of: CGRect(x: 0, y: 0, width: 390, height: 20), in: layOut(row(list.sessions[1]), in: CGSize(width: 390, height: 20)), where: TileTests.orange)
        let calm = try share(of: CGRect(x: 0, y: 0, width: 390, height: 20), in: layOut(row(list.sessions[0]), in: CGSize(width: 390, height: 20)), where: TileTests.orange)
        #expect(warm > 0.002 && calm == 0, "\(warm) \(calm)")
        try capture(VStack(spacing: 6) { ForEach(list.sessions) { row($0) } }.frame(width: 390).padding(12).background(.black), named: "R49-render-rows-T143")

        let tile = AgentsTile(sessions: list, logos: logos, size: .wide)
        let ideal = NSHostingView(rootView: tile).fittingSize
        #expect(ideal.width <= 190 && ideal.height <= 90, "\(ideal)")
        let bare = AgentSessionList()
        world.attach(to: bare)
        for session in list.sessions.reversed() { bare.update(session.id, folder: session.folder, state: session.state) }
        #expect(NSHostingView(rootView: AgentsTile(sessions: bare, logos: logos, size: .wide)).fittingSize.height == ideal.height)
        try capture(tile.frame(width: 190, height: 90).background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12)).padding(12).background(.black), named: "R49-render-tile-T143")
    }
}
