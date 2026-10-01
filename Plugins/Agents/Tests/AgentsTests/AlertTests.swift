import AppKit
import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// One alert for each wait, finished turn and ended session of both agents, with the agent's logo.
/// What the Codex bridge's terminal lookup finds, by working folder.
@MainActor
final class FolderTerminals {
    var byFolder = ["/Users/me/notch-the-rock": ghostty]
}

@MainActor
@Suite struct AlertTests {
    static let magenta = NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
    static let thread1 = CodexBridgeTests.thread1
    static let jump = AttentionResponse.answered(AttentionAnswer(buttonID: ClaudeBridge.jumpButtonID))
    let host = FakeHost()
    let activator = FakeActivator()
    let logos = FakeLogos()
    let claude: ClaudeBridge

    init() throws {
        // Claude's mark is a template drawn black; Codex's keeps its own colour.
        logos.images[.claude] = solidLogo(.black, template: true)
        logos.images[.codex] = solidLogo(Self.magenta, template: false)
        claude = ClaudeBridge(context: try makeContext(host: host, directory: try makeDirectory()), activator: activator, logos: logos)
    }

    func hook(_ event: HookEvent, _ fields: String = "", session: String = "s1") throws -> HookMessage {
        let payload = #"{"session_id":"\#(session)","cwd":"/Users/me/work/tide-pool","hook_event_name":"\#(event.rawValue)"\#(fields)}"#
        return HookMessage(event: event, payload: try json(payload), context: HookContext(terminal: ghostty, projectDir: nil, claudePID: 4242))
    }

    /// Delivers `message` and returns the alerts it raised.
    func alerts(_ message: HookMessage) async -> [AttentionRequest] {
        let before = host.requests.count
        await claude.receive(message)?.value
        return Array(host.requests[before...])
    }

    /// True when most of the alert's icon, drawn at 16 points on black, `matches`.
    func icon(_ request: AttentionRequest, _ matches: (UInt8, UInt8, UInt8) -> Bool) throws -> Bool {
        let image = try #require(request.sourceIcon)
        let view = layOut(image.resizable().frame(width: 16, height: 16), in: CGSize(width: 16, height: 16))
        return try share(of: CGRect(x: 4, y: 4, width: 8, height: 8), in: view, where: matches) > 0.9
    }

    static func light(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 180 && g > 180 && b > 180 }
    static func pink(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 180 && g < 130 && b > 180 }

    @Test func R40__each_claude_event_alerts_once_with_logo_folder_and_message() async throws {
        #expect(await alerts(try hook(.sessionStart, #","source":"startup""#)).isEmpty)
        let waiting = await alerts(try hook(.notification, #","notification_type":"idle_prompt","message":"Claude is waiting for your input""#))
        #expect(await alerts(try hook(.userPromptSubmit, #","prompt":"go""#)).isEmpty)
        let finished = await alerts(try hook(.stop, #","stop_reason":"end_turn""#))
        host.responses = [Self.jump]
        let ended = await alerts(try hook(.sessionEnd, #","reason":"prompt_input_exit""#))

        for (raised, text) in [(waiting, "Claude is waiting for your input"), (finished, "Claude Code가 작업을 마쳤어요."), (ended, "Claude Code 세션이 끝났어요.")] {
            #expect(raised.count == 1)
            let request = try #require(raised.first)
            #expect(request.title == "tide-pool")
            #expect(request.message == text)
            #expect(request.buttons.map(\.title) == ["터미널로 이동"])
            // The template mark is tinted to the notch's light foreground.
            #expect(try icon(request, Self.light))
        }
        // Tapping the session-ended alert goes to the session's terminal.
        #expect(activator.activated == [ghostty])

        // Without the Claude app's mark the alert shows the agent's symbol.
        let plain = ClaudeBridge(context: try makeContext(host: host, directory: try makeDirectory()), activator: activator)
        #expect(plain.notificationRequest(sessionID: "s1", title: "tide-pool", message: "m").sourceIcon != nil)
    }

    @Test func R40__a_finished_turn_and_its_idle_reminder_alert_once() async throws {
        #expect(await alerts(try hook(.stop)).count == 1)
        // Claude Code's idle reminder for the same pause adds nothing.
        #expect(await alerts(try hook(.notification, #","notification_type":"idle_prompt","message":"waiting""#)).isEmpty)
        // A wait within a turn always alerts, even when no prompt hook arrived since (hooks installed
        // before UserPromptSubmit was added).
        #expect(await alerts(try hook(.notification, #","notification_type":"elicitation_dialog","message":"asks""#)).count == 1)
        // Another session's reminder is its own pause.
        #expect(await alerts(try hook(.notification, #","notification_type":"idle_prompt","message":"waiting""#, session: "s2")).count == 1)
        // A new prompt starts a new pause: its turn and its reminder after a request alert again.
        #expect(await alerts(try hook(.userPromptSubmit)).isEmpty)
        #expect(await alerts(try hook(.stop)).count == 1)
        #expect(await alerts(try hook(.notification, #","notification_type":"idle_prompt","message":"waiting""#)).isEmpty)
        _ = await claude.decide(try hook(.permissionRequest, #","tool_name":"Bash","tool_input":{"command":"ls"}"#))
        #expect(await alerts(try hook(.notification, #","notification_type":"agent_needs_input","message":"needs you""#)).count == 1)
        // Every session end alerts, /clear's too.
        #expect(await alerts(try hook(.sessionEnd, #","reason":"clear""#)).count == 1)
        #expect(await alerts(try hook(.sessionEnd, #","reason":"logout""#)).count == 1)
    }

    @Test func R40__codex_turns_and_closed_threads_alert_once_with_logo_folder_and_message() async throws {
        final class Terminals { var byFolder = ["/Users/me/notch-the-rock": ghostty] }
        let terminals = Terminals()
        let outbox = Outbox()
        let codex = CodexBridge(
            context: try makeContext(host: host, directory: try makeDirectory()),
            activator: activator,
            terminal: { cwd in cwd.flatMap { terminals.byFolder[$0] } },
            logos: logos
        )
        codex.open { [outbox] in outbox.messages.append($0) }
        codex.receive(try codexFixture("initializeResponse"))
        codex.receive(try codexFixture("loadedListPage1"))
        codex.receive(try codexFixture("resumeResponse"))
        func codexAlerts(_ message: JSONValue) async -> [AttentionRequest] {
            let before = host.requests.count
            await codex.receive(message)?.value
            return Array(host.requests[before...])
        }
        let thread = Self.thread1
        let finished = await codexAlerts(try codexFixture("turnCompleted"))
        let failed = await codexAlerts(try jsonValue(#"{"method":"turn/completed","params":{"threadId":"\#(thread)","turn":{"id":"t2","items":[],"status":"failed"}}}"#))
        #expect(await codexAlerts(try codexFixture("turnInterrupted")).isEmpty)
        // The TUI is gone once its thread closes: the alert still knows the terminal the row had.
        terminals.byFolder = [:]
        host.responses = [Self.jump]
        let closed = await codexAlerts(try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(thread)"}}"#))

        for (raised, text) in [(finished, "Codex가 작업을 마쳤어요."), (failed, "Codex 작업이 오류로 멈췄어요."), (closed, "Codex 세션이 끝났어요.")] {
            #expect(raised.count == 1)
            let request = try #require(raised.first)
            #expect(request.title == "notch-the-rock")
            #expect(request.message == text)
            #expect(try icon(request, Self.pink))
        }
        #expect(closed.first?.buttons.map(\.title) == ["터미널로 이동"])
        #expect(activator.activated == [ghostty])
        // One alert per thread end; a lost connection ends no session.
        #expect(await codexAlerts(try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(thread)"}}"#)).isEmpty)
        let count = host.requests.count
        codex.close()
        #expect(host.requests.count == count)
    }

    /// A Codex bridge on a connection that listed `thread1`, working in /Users/me/notch-the-rock, with
    /// the terminal lookup `terminals` answers.
    func joinedCodex(_ terminals: FolderTerminals, world: SessionWorld? = nil) throws -> CodexBridge {
        let codex = CodexBridge(
            context: try makeContext(host: host, directory: try makeDirectory()),
            activator: activator,
            terminal: { cwd in cwd.flatMap { terminals.byFolder[$0] } },
            logos: logos
        )
        world?.attach(to: codex.screen.sessions)
        codex.open { _ in }
        codex.receive(try codexFixture("initializeResponse"))
        codex.receive(try codexFixture("loadedListPage1"))
        codex.receive(try codexFixture("resumeResponse"))
        return codex
    }

    @Test func R40__a_codex_thread_closed_after_its_row_was_pruned_still_alerts_once() async throws {
        let world = SessionWorld()
        let codex = try joinedCodex(FolderTerminals(), world: world)
        let key = AgentSession.Key(agent: .codex, id: Self.thread1)
        #expect(codex.screen.sessions[key] != nil)
        world.now += AgentSessionList.silenceLimit + 60
        codex.screen.sessions.prune()
        #expect(codex.screen.sessions[key] == nil)

        let closed = try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(Self.thread1)"}}"#)
        let before = host.requests.count
        await codex.receive(closed)?.value
        #expect(host.requests[before...].map(\.message) == ["Codex 세션이 끝났어요."])
        await codex.receive(closed)?.value
        #expect(host.requests.count == before + 1)
    }

    @Test func R40__codex_alerts_jump_to_the_sessions_own_terminal_while_another_holds_its_folder() async throws {
        let terminals = FolderTerminals()
        let codex = try joinedCodex(terminals)
        // Another Codex TUI now works in the same folder, in another terminal.
        terminals.byFolder["/Users/me/notch-the-rock"] = TerminalLocation(bundleID: "com.apple.Terminal", tty: "/dev/ttys009")
        host.responses = [Self.jump]
        await codex.receive(try codexFixture("turnCompleted"))?.value
        host.responses = [Self.jump]
        await codex.receive(try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(Self.thread1)"}}"#))?.value
        #expect(activator.activated == [ghostty, ghostty])
    }

    @Test func R40__a_rejoining_codex_thread_keeps_the_terminal_it_joined_in() async throws {
        let terminals = FolderTerminals()
        let codex = try joinedCodex(terminals)
        let key = AgentSession.Key(agent: .codex, id: Self.thread1)
        #expect(codex.screen.sessions[key]?.terminal == ghostty)
        // Another Codex TUI now works in the same folder, in another terminal; the connection drops and
        // the thread is listed and resumed again.
        let other = TerminalLocation(bundleID: "com.apple.Terminal", tty: "/dev/ttys009")
        terminals.byFolder["/Users/me/notch-the-rock"] = other
        codex.close()
        codex.open { _ in }
        codex.receive(try codexFixture("initializeResponse"))
        codex.receive(try codexFixture("loadedListPage1"))
        codex.receive(try codexFixture("resumeResponse"))
        #expect(codex.screen.sessions[key]?.terminal == ghostty)
        host.responses = [Self.jump]
        await codex.receive(try codexFixture("turnCompleted"))?.value
        host.responses = [Self.jump]
        await codex.receive(try jsonValue(#"{"method":"thread/closed","params":{"threadId":"\#(Self.thread1)"}}"#))?.value
        #expect(activator.activated == [ghostty, ghostty])
    }

    @Test func R40__render_alerts_with_a_fake_logo() throws {
        logos.images[.claude] = solidLogo(Self.magenta, template: false)
        claude.receive(try hook(.sessionStart))
        #expect(AgentsSettingsView.alertNote.contains("같은 멈춤"))
        let requests = [
            claude.notificationRequest(sessionID: "s1", title: "tide-pool", message: "Claude Code가 입력을 기다려요."),
            claude.notificationRequest(sessionID: "s1", title: "tide-pool", message: "Claude Code 세션이 끝났어요."),
        ]
        try capture(
            VStack(spacing: 0) {
                ForEach(Array(requests.enumerated()), id: \.offset) { AttentionPreview(request: $0.element) }
            },
            named: "R40-render-alert-T119"
        )
    }
}
