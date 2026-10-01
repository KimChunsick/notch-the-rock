import AppKit
import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

@MainActor
@Suite struct CodexSessionTests {
    static let thread1 = CodexBridgeTests.thread1
    static let thread3 = "019a0000-0000-7000-8000-000000000003"
    let host = FakeHost()
    let outbox = Outbox()
    let world = SessionWorld()
    let bridge: CodexBridge

    init() throws {
        let terminals = ["/Users/me/notch-the-rock": ghostty]
        bridge = CodexBridge(
            context: try makeContext(host: host, directory: try makeDirectory()),
            activator: FakeActivator(),
            terminal: { cwd in cwd.flatMap { terminals[$0] } }
        )
        world.attach(to: bridge.screen.sessions)
        bridge.open { [outbox] in outbox.messages.append($0) }
    }

    var list: AgentSessionList { bridge.screen.sessions }

    func session(_ thread: String) -> AgentSession? {
        list[AgentSession.Key(agent: .codex, id: thread)]
    }

    func notification(_ method: String, _ params: String) throws -> JSONValue {
        try jsonValue(#"{"method":"\#(method)","params":\#(params)}"#)
    }

    func connect() throws {
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        bridge.receive(try codexFixture("resumeResponse"))
    }

    @Test func R33__codex_threads_and_turns_move_the_session_list() async throws {
        bridge.receive(try codexFixture("initializeResponse"))
        bridge.receive(try codexFixture("loadedListPage1"))
        #expect(list.sessions.isEmpty)
        bridge.receive(try codexFixture("resumeResponse"))
        let listed = try #require(session(Self.thread1))
        #expect(listed.folder == "notch-the-rock" && listed.state == .idle && listed.terminal == ghostty && listed.pid == nil)
        world.now += 1
        bridge.receive(try codexFixture("threadStarted"))
        #expect(session(Self.thread3)?.folder == "other-project" && session(Self.thread3)?.state == .idle)
        #expect(list.sessions.map(\.id.id) == [Self.thread3, Self.thread1])

        let turn = #"{"id":"019a0000-0000-7000-8000-0000000000a1","items":[],"status":"inProgress"}"#
        bridge.receive(try notification("turn/started", #"{"threadId":"\#(Self.thread1)","turn":\#(turn)}"#))
        #expect(session(Self.thread1)?.state == .working)

        // An approval waits until it is answered: in the notch here.
        host.responses = [.answered(AttentionAnswer(buttonID: CodexBridge.allowButtonID, choices: [:], text: nil))]
        let allowed = bridge.receive(try codexFixture("commandApproval"))
        #expect(session(Self.thread1)?.state == .awaitingApproval)
        await allowed?.value
        #expect(outbox.messages.last?["result"]?["decision"]?.string == "accept")
        #expect(session(Self.thread1)?.state == .working)

        // A question waits until it is answered: in the TUI here.
        host.waitsForCancellation = true
        let question = bridge.receive(try codexFixture("userInput"))
        #expect(await eventually { !host.requests.isEmpty && host.requests.count == 2 })
        #expect(session(Self.thread1)?.state == .awaitingAnswer)
        bridge.receive(try notification("serverRequest/resolved", #"{"threadId":"\#(Self.thread1)","requestId":12}"#))
        await question?.value
        #expect(session(Self.thread1)?.state == .working)

        bridge.receive(try codexFixture("turnCompleted"))
        #expect(session(Self.thread1)?.state == .idle)
        bridge.receive(try notification("thread/closed", #"{"threadId":"\#(Self.thread3)"}"#))
        #expect(list.sessions.map(\.id.id) == [Self.thread1])
    }

    @Test func R33__claude_and_codex_sessions_render_with_their_own_logos() throws {
        world.now = .now - 240
        let logos = FakeLogos()
        logos.images[.claude] = solidLogo(.black, template: true)
        logos.images[.codex] = solidLogo(NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1), template: false)
        list.update(AgentSession.Key(agent: .claude, id: "s1"), folder: "rock-garden", state: .working, terminal: ghostty)
        world.now += 60
        try connect()
        let rows = list.sessions
        #expect(rows.map(\.agent) == [.codex, .claude])
        #expect(rows.map(\.folder) == ["notch-the-rock", "rock-garden"])
        #expect(rows.map(\.state.title) == ["대기 중", "작업 중"])

        let screen = AgentsScreen(model: bridge.screen, logos: logos)
        let ideal = NSHostingView(rootView: screen).fittingSize
        let view = layOut(screen, in: CGSize(width: ideal.width + 80, height: ideal.height))
        try capture(view, named: "R33-render-both-T114")
        print("R33 both agents ideal \(ideal)")
        let second = (ideal.height + 6) / 2
        let magenta = try share(of: CGRect(x: 3, y: 3, width: 10, height: 10), in: view) { r, g, b in r > 150 && b > 150 && Int(g) + 80 < Int(r) }
        let white = try share(of: CGRect(x: 3, y: second + 3, width: 10, height: 10), in: view) { r, g, b in min(r, g, b) > 200 }
        #expect(magenta > 0.8, "the Codex row does not show the Codex logo: \(magenta)")
        #expect(white > 0.8, "the Claude row does not show the Claude logo: \(white)")
    }
}

extension CodexLinkTests {
    @Test func R33__a_lost_connection_clears_codex_sessions_until_they_are_listed_again() async throws {
        defer { try? FileManager.default.removeItem(atPath: home) }
        let endpoint = CodexEndpoint(home: URL(fileURLWithPath: home))
        let listener = try listen(at: endpoint.socketPath)
        defer { close(listener) }
        let bridge = CodexBridge(context: try makeContext(host: host, directory: try makeDirectory()), activator: FakeActivator(), terminal: { _ in nil })
        let sessions = bridge.screen.sessions
        sessions.update(AgentSession.Key(agent: .claude, id: "s1"), folder: "rock-garden", state: .idle)
        let first = FakeConnection(), second = FakeConnection()
        let queue = ConnectionQueue([first, second])
        let link = CodexLink(
            supervisor: CodexSupervisor(endpoint: endpoint, executable: nil, launcher: FakeLauncher(socketPath: endpoint.socketPath)),
            bridge: bridge,
            log: { _ in },
            sleep: { _ in try? await Task.sleep(for: .milliseconds(20)) },
            connect: { _ in try queue.next() }
        )
        func list(on connection: FakeConnection) async {
            #expect(await eventually { connection.sent.count == 1 })
            connection.deliver(#"{"id":1,"result":{}}"#)
            #expect(await eventually { connection.sent.count == 3 })
            connection.deliver(#"{"id":2,"result":{"data":["t1"],"nextCursor":null}}"#)
            #expect(await eventually { connection.sent.count == 4 })
            connection.deliver(#"{"id":3,"result":{"thread":{"id":"t1","cwd":"/Users/me/tide-pool","status":{"type":"idle"}}}}"#)
        }
        link.start()
        await list(on: first)
        #expect(await eventually { sessions.sessions.count == 2 })
        #expect(sessions[AgentSession.Key(agent: .codex, id: "t1")]?.folder == "tide-pool")
        // The server goes away: no Codex row stays, the Claude one does.
        first.finish()
        #expect(await eventually { sessions.sessions.map(\.agent) == [.claude] })
        // Connected again, the list brings them back.
        await list(on: second)
        #expect(await eventually { sessions.sessions.count == 2 })
        link.stop()
        second.finish()
    }
}
