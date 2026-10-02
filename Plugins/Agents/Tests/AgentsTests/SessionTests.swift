import AppKit
import Foundation
import HookBridge
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// The time and the running processes the session list sees.
@MainActor
final class SessionWorld {
    var now = Date(timeIntervalSince1970: 1_790_000_000)
    var alive: Set<pid_t> = [4242]

    func attach(to list: AgentSessionList) {
        list.now = { [unowned self] in now }
        list.isAlive = { [unowned self] in alive.contains($0) }
    }
}

/// Marks given by the test instead of the installed apps.
@MainActor
final class FakeLogos: AgentLogoProviding {
    var images: [AgentKind: NSImage] = [:]

    func logo(for agent: AgentKind) -> NSImage? { images[agent] }
}

/// A 16-point square of `color`.
@MainActor
func solidLogo(_ color: NSColor, template: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
        color.setFill()
        rect.fill()
        return true
    }
    image.isTemplate = template
    return image
}

/// The share of pixels in `rect` (points, top-left origin) of a laid-out `view` that `matches`.
@MainActor
func share(of rect: CGRect, in view: NSView, where matches: (UInt8, UInt8, UInt8) -> Bool) throws -> Double {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / view.bounds.width
    var hits = 0, total = 0
    for y in Int(rect.minY * scale)..<Int(rect.maxY * scale) {
        for x in Int(rect.minX * scale)..<Int(rect.maxX * scale) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            total += 1
            if matches(UInt8(color.redComponent * 255), UInt8(color.greenComponent * 255), UInt8(color.blueComponent * 255)) { hits += 1 }
        }
    }
    return total == 0 ? 0 : Double(hits) / Double(total)
}

@MainActor
@Suite struct SessionTests {
    let host = FakeHost()
    let activator = FakeActivator()
    let world = SessionWorld()
    let bridge: ClaudeBridge
    let key = AgentSession.Key(agent: .claude, id: "s1")

    init() throws {
        bridge = ClaudeBridge(context: try makeContext(host: host, directory: try makeDirectory()), activator: activator)
        world.attach(to: bridge.screen.sessions)
    }

    var list: AgentSessionList { bridge.screen.sessions }
    var state: AgentSessionState? { list[key]?.state }

    func message(_ event: HookEvent, _ fields: String = "", session: String = "s1", pid: pid_t? = 4242) throws -> HookMessage {
        let payload = #"{"session_id":"\#(session)","cwd":"/Users/me/work/rock-garden","hook_event_name":"\#(event.rawValue)"\#(fields)}"#
        return HookMessage(event: event, payload: try json(payload), context: HookContext(terminal: ghostty, projectDir: nil, claudePID: pid))
    }

    static let bash = #","tool_name":"Bash","tool_input":{"command":"ls"}"#
    static let read = #","tool_name":"Read","tool_input":{"file_path":"/Users/me/work/rock-garden/README.md"}"#
    static let question = #","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which format?","header":"Format","options":[{"label":"Summary","description":""},{"label":"Detailed","description":""}],"multiSelect":false}]}"#

    /// Runs a request that waits in the notch until the hook goes away, as when the user answers in
    /// the terminal, and returns the session's state while it waited.
    func stateWhileWaiting(_ request: HookMessage) async throws -> AgentSessionState? {
        host.waitsForCancellation = true
        defer { host.waitsForCancellation = false }
        let count = host.requests.count
        let task = Task { await bridge.decide(request) }
        while host.requests.count == count { try await Task.sleep(for: .milliseconds(10)) }
        let waiting = state
        task.cancel()
        #expect(await task.value == nil)
        return waiting
    }

    @Test func R33__claude_hook_events_move_the_session_through_its_states() async throws {
        bridge.receive(try message(.sessionStart, #","source":"startup""#))
        let started = try #require(list[key])
        #expect(started.folder == "rock-garden" && started.state == .idle && started.terminal == ghostty && started.pid == 4242)

        world.now += 60
        bridge.receive(try message(.userPromptSubmit, #","prompt":"run the tests""#))
        #expect(state == .working && list[key]?.changed == world.now)

        // Waiting for approval until answered: in the terminal (the hook goes away) or in the notch.
        #expect(try await stateWhileWaiting(try message(.permissionRequest, Self.bash)) == .awaitingApproval)
        #expect(state == .working)
        host.responses = [.answered(AttentionAnswer(buttonID: ClaudeBridge.allowButtonID))]
        #expect(await bridge.decide(try message(.permissionRequest, Self.bash)) == .allow)
        #expect(state == .working)
        // Handed to the terminal, the terminal asks now: the session still waits.
        host.responses = [.released]
        #expect(await bridge.decide(try message(.permissionRequest, Self.bash)) == nil)
        #expect(state == .awaitingApproval)

        #expect(try await stateWhileWaiting(try message(.preToolUse, Self.question)) == .awaitingAnswer)
        #expect(state == .working)
        host.responses = [.answered(AttentionAnswer(buttonID: nil, choices: ["0": ["Summary"]], text: nil))]
        #expect(await bridge.decide(try message(.preToolUse, Self.question)) != nil)
        #expect(state == .working)

        bridge.receive(try message(.stop, #","stop_reason":"end_turn""#))
        #expect(state == .idle)
        bridge.receive(try message(.sessionEnd, #","reason":"prompt_input_exit""#))
        #expect(list[key] == nil && list.sessions.isEmpty)

        // A session that started before the app joins on its next event.
        bridge.receive(try message(.notification, #","notification_type":"idle_prompt","message":"waiting""#, session: "s2"))
        #expect(list.sessions.map(\.id.id) == ["s2"] && list.sessions.first?.state == .idle)
    }

    @Test func R33__sessions_whose_process_is_gone_or_that_stay_silent_12_hours_drop_out() throws {
        world.alive = [100, 200]
        bridge.receive(try message(.sessionStart, session: "a", pid: 100))
        world.now += 1
        bridge.receive(try message(.sessionStart, session: "b", pid: 200))
        world.now += 1
        bridge.receive(try message(.sessionStart, session: "c", pid: nil))
        list.prune()
        #expect(list.sessions.map(\.id.id) == ["c", "b", "a"])

        world.alive = [200]
        list.prune()
        #expect(list.sessions.map(\.id.id) == ["c", "b"])

        world.now += AgentSessionList.silenceLimit - 60
        bridge.receive(try message(.userPromptSubmit, session: "b", pid: 200))
        world.now += 61
        list.prune()
        #expect(list.sessions.map(\.id.id) == ["b"])

        // The real check: this process exists; one that exited and was reaped does not.
        #expect(AgentSessionList.processExists(getpid()))
        let exited = Process()
        exited.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try exited.run()
        exited.waitUntilExit()
        #expect(!AgentSessionList.processExists(exited.processIdentifier))
    }

    @Test func R33__silence_drops_only_a_session_whose_process_is_unknown() throws {
        world.alive = [100]
        bridge.receive(try message(.sessionStart, session: "alive", pid: 100))
        bridge.receive(try message(.sessionStart, session: "unknown", pid: nil))
        world.now += AgentSessionList.silenceLimit + 60
        list.prune()
        // A process that still runs keeps its session open, however long it stays silent.
        #expect(list.sessions.map(\.id.id) == ["alive"])
        world.alive = []
        list.prune()
        #expect(list.sessions.isEmpty)
    }

    @Test func R33__waiting_notifications_move_the_session_to_its_waiting_state() throws {
        for type in ["elicitation_dialog", "agent_needs_input"] {
            bridge.receive(try message(.userPromptSubmit, #","prompt":"go""#))
            #expect(state == .working)
            bridge.receive(try message(.notification, #","notification_type":"\#(type)","message":"asks""#))
            #expect(state == .awaitingAnswer, "\(type)")
        }
        bridge.receive(try message(.notification, #","notification_type":"idle_prompt","message":"waiting""#))
        #expect(state == .idle)
        // A notice that is no wait keeps the state.
        bridge.receive(try message(.userPromptSubmit, #","prompt":"go""#))
        bridge.receive(try message(.notification, #","notification_type":"auth_success","message":"ok""#))
        #expect(state == .working)
    }

    @Test func R33__work_resuming_after_a_terminal_answer_moves_the_session_back_to_working() async throws {
        bridge.receive(try message(.userPromptSubmit, #","prompt":"build it""#))
        // Handed to the terminal: the terminal asks now.
        host.responses = [.released]
        #expect(await bridge.decide(try message(.permissionRequest, Self.bash)) == nil)
        #expect(state == .awaitingApproval)
        // Approved there, the tool runs and its PostToolUse hook reaches the plugin through the helper.
        let server = try TestServer()
        defer { server.stop() }
        let runner = HookRunner(
            socketPath: server.path, environment: [:],
            readInput: { Data(#"{"session_id":"s1","cwd":"/Users/me/work/rock-garden","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"a.txt"}}"#.utf8) },
            findTerminal: { ghostty }, findClaudeProcess: { 4242 }
        )
        #expect(await run(runner, ["PostToolUse"]).isEmpty)
        let received = try #require(await server.inbox.wait(for: 1).first)
        #expect(received.event == .postToolUse)
        bridge.receive(received)
        #expect(state == .working)
        // A question asked by an MCP server and answered in the terminal ends the same way.
        bridge.receive(try message(.notification, #","notification_type":"elicitation_dialog","message":"asks""#))
        #expect(state == .awaitingAnswer)
        bridge.receive(try message(.postToolUse, #","tool_name":"mcp__forms__ask""#))
        #expect(state == .working)
    }

    @Test func R40__a_request_handed_to_the_terminal_waits_until_its_tool_ends_or_the_session_moves_on() async throws {
        bridge.receive(try message(.userPromptSubmit, #","prompt":"build it""#))
        // Approved in the terminal, the tool fails: its failure ends the wait.
        host.responses = [.released]
        #expect(await bridge.decide(try message(.permissionRequest, Self.bash)) == nil)
        #expect(state == .awaitingApproval)
        bridge.receive(try message(.postToolUseFailure, Self.bash + #","tool_use_id":"toolu_1","error":"exit 1","is_interrupt":false"#))
        #expect(state == .working)

        // Timed out: another tool's end and the terminal's own permission notice keep the wait; the
        // finished turn ends it.
        host.responses = [.timedOut]
        #expect(await bridge.decide(try message(.permissionRequest, Self.bash)) == nil)
        bridge.receive(try message(.postToolUse, Self.read + #","tool_use_id":"toolu_2","tool_response":{}"#))
        #expect(state == .awaitingApproval)
        bridge.receive(try message(.notification, #","notification_type":"permission_prompt","message":"Claude needs your permission""#))
        #expect(state == .awaitingApproval)
        bridge.receive(try message(.stop, #","stop_reason":"end_turn""#))
        #expect(state == .idle)
        // No wait is left behind: the next turn's tool ends move the session as before.
        bridge.receive(try message(.userPromptSubmit, #","prompt":"again""#))
        bridge.receive(try message(.postToolUse, Self.read + #","tool_use_id":"toolu_3","tool_response":{}"#))
        #expect(state == .working)

    }

    @Test func R33__a_tool_end_ends_only_the_wait_it_belongs_to() async throws {
        bridge.receive(try message(.userPromptSubmit, #","prompt":"build it""#))
        let bashRequest = try message(.permissionRequest, Self.bash)
        let questionRequest = try message(.preToolUse, Self.question + #","tool_use_id":"toolu_q""#)
        host.waitsForCancellation = true
        let permission = Task { await bridge.decide(bashRequest) }
        #expect(await eventually { host.requests.count == 1 })
        #expect(state == .awaitingApproval)
        // Another tool of the same session ends while the request waits in the notch.
        bridge.receive(try message(.postToolUse, Self.read + #","tool_use_id":"toolu_2","tool_response":{}"#))
        #expect(state == .awaitingApproval)

        // A question joins it; answering one of the two leaves the other one waiting.
        let question = Task { await bridge.decide(questionRequest) }
        #expect(await eventually { host.requests.count == 2 })
        #expect(state == .awaitingAnswer)
        question.cancel()
        _ = await question.value
        #expect(state == .awaitingApproval)

        // The request's own tool end (the same tool and input; PermissionRequest carries no
        // tool_use_id) ends it, and no wait is left.
        bridge.receive(try message(.postToolUse, Self.bash + #","tool_use_id":"toolu_1","tool_response":{}"#))
        #expect(state == .working)
        permission.cancel()
        _ = await permission.value
        #expect(state == .working)

        // A question handed to the terminal ends with its own tool_use_id, not with another call of
        // the same tool and input.
        host.waitsForCancellation = false
        host.responses = [.released]
        #expect(await bridge.decide(try message(.preToolUse, Self.question + #","tool_use_id":"toolu_q2""#)) == nil)
        #expect(state == .awaitingAnswer)
        bridge.receive(try message(.postToolUse, Self.question + #","tool_use_id":"toolu_q3","tool_response":{}"#))
        #expect(state == .awaitingAnswer)
        bridge.receive(try message(.postToolUse, Self.question + #","tool_use_id":"toolu_q2","tool_response":{}"#))
        #expect(state == .working)
    }

    @Test func R33__a_notification_keeps_a_request_handed_to_the_terminal_waiting() async throws {
        // Each notice still shows the state it shows today.
        let notices: [(fields: String, shows: AgentSessionState)] = [
            (#","notification_type":"permission_prompt","message":"Claude needs your permission""#, .awaitingApproval),
            (#","notification_type":"elicitation_dialog","message":"asks""#, .awaitingAnswer),
            (#","notification_type":"agent_needs_input","message":"asks""#, .awaitingAnswer),
            (#","notification_type":"idle_prompt","message":"waiting""#, .idle),
            (#","message":"Claude needs your attention""#, .awaitingApproval),
        ]
        for notice in notices {
            bridge.receive(try message(.userPromptSubmit, #","prompt":"build it""#))
            host.responses = [.released]
            #expect(await bridge.decide(try message(.permissionRequest, Self.bash)) == nil)
            #expect(state == .awaitingApproval)
            // The notice answers nothing: another tool's end still finds the request waiting.
            bridge.receive(try message(.notification, notice.fields))
            #expect(state == notice.shows, "\(notice.fields)")
            bridge.receive(try message(.postToolUse, Self.read + #","tool_use_id":"toolu_2","tool_response":{}"#))
            #expect(state == notice.shows, "\(notice.fields)")
            bridge.receive(try message(.postToolUse, Self.bash + #","tool_use_id":"toolu_1","tool_response":{}"#))
            #expect(state == .working, "\(notice.fields)")
        }
    }

    @Test func R33__an_answered_call_never_ends_an_identical_request_that_still_waits() async throws {
        bridge.receive(try message(.userPromptSubmit, #","prompt":"build it""#))
        let request = try message(.permissionRequest, Self.bash)
        func end(_ id: String) throws {
            bridge.receive(try message(.postToolUse, Self.bash + #","tool_use_id":"\#(id)","tool_response":{}"#))
        }
        // A waits on the Agents screen, B in the notch: the same tool and input.
        host.responses = [.answered(AttentionAnswer(buttonID: ClaudeBridge.detailsButtonID))]
        let first = Task { await bridge.decide(request) }
        #expect(await eventually { !bridge.screen.items.isEmpty })
        host.waitsForCancellation = true
        let second = Task { await bridge.decide(request) }
        #expect(await eventually { host.requests.count == 2 })
        bridge.screen.respond(to: try #require(bridge.screen.items.first).id, with: .allow)
        #expect(await first.value == .allow)
        #expect(state == .awaitingApproval)
        // A's end carries nothing that tells it from B's, so it leaves B waiting; the next one is B's.
        try end("toolu_a")
        #expect(state == .awaitingApproval)
        try end("toolu_b")
        #expect(state == .working)
        second.cancel()
        _ = await second.value
        #expect(state == .working)

        // Answered in the terminal while the notch held it: the same.
        let third = Task { await bridge.decide(request) }
        #expect(await eventually { host.requests.count == 3 })
        let fourth = Task { await bridge.decide(request) }
        #expect(await eventually { host.requests.count == 4 })
        third.cancel()
        _ = await third.value
        #expect(state == .awaitingApproval)
        try end("toolu_c")
        #expect(state == .awaitingApproval)
        fourth.cancel()
        _ = await fourth.value
        try end("toolu_d")
        #expect(state == .working)

        // The finished turn clears answered calls: the next turn's request ends with its own end.
        host.waitsForCancellation = false
        host.responses = [.answered(AttentionAnswer(buttonID: ClaudeBridge.allowButtonID))]
        #expect(await bridge.decide(request) == .allow)
        bridge.receive(try message(.stop, #","stop_reason":"end_turn""#))
        #expect(state == .idle)
        host.responses = [.released]
        #expect(await bridge.decide(request) == nil)
        #expect(state == .awaitingApproval)
        try end("toolu_e")
        #expect(state == .working)
    }

    @Test func R33__under_a_request_the_list_scrolls_to_its_last_row() async throws {
        let offer = CGSize(width: 390, height: 210)
        for index in 1...12 {
            world.now += 1
            bridge.receive(try message(.sessionStart, session: "s\(index)"))
        }
        let request = Task {
            await bridge.screen.show(
                title: "rock-garden · Bash",
                content: .permission(OperationDetail(tool: "Bash", input: try? json(#"{"command":"npm run build"}"#))),
                accent: ClaudeBridge.accent, takesDenyReason: true, until: .now + .seconds(60)
            )
        }
        defer { request.cancel() }
        #expect(await eventually { !bridge.screen.items.isEmpty })
        let screen = AgentsScreen(model: bridge.screen)
        let root = layOut(screen, in: offer)
        try capture(root, named: "R33-render-list-under-request-390x210-T126")

        // The request stays whole: everything it needs fits the offer and its controls are in view.
        let needed = NSHostingController(rootView: screen).sizeThatFits(in: offer)
        #expect(needed.height <= offer.height, "the screen needs \(needed)")
        let (controls, _) = pinnedControls(in: root)
        #expect(controls.contains { $0.control is NSTextField })
        for (control, frame) in controls {
            #expect(root.bounds.contains(frame), "\(type(of: control)) at \(frame) is outside \(root.bounds)")
        }

        // The list scrolls in its own view under the request, inside the offer, and holds all twelve rows.
        var scrollViews: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { scrollViews.append(scroll) } else { view.subviews.forEach(walk) }
        }
        walk(root)
        #expect(scrollViews.count == 2)
        let below = scrollViews.max { a, b in
            let (fa, fb) = (a.convert(a.bounds, to: root), b.convert(b.bounds, to: root))
            return root.isFlipped ? fa.minY < fb.minY : fa.minY > fb.minY
        }
        let listView = try #require(below)
        let listFrame = listView.convert(listView.bounds, to: root)
        #expect(root.bounds.contains(listFrame))
        // Each row is a view of its own in the list's scroll view (its focus ring, which keyboard focus
        // moves to); the last one lies below what the list shows.
        let rowHeight = NSHostingView(rootView: AgentSessionRow(session: list.sessions[0], logo: nil, open: { _ in })).fittingSize.height
        var rows: [NSView] = []
        func collectRows(_ view: NSView) {
            for sub in view.subviews {
                if sub.frame.height == rowHeight { rows.append(sub) } else { collectRows(sub) }
            }
        }
        collectRows(listView.contentView)
        #expect(rows.count == 12)
        let lastRow = try #require(rows.max { $0.convert($0.bounds, to: root).maxY < $1.convert($1.bounds, to: root).maxY })
        #expect(!listFrame.contains(lastRow.convert(lastRow.bounds, to: root)))
        // Scrolled to its end, the last row shows inside the list.
        let end = lastRow.convert(lastRow.bounds, to: listView.contentView).maxY - listView.contentView.bounds.height
        listView.contentView.scroll(to: NSPoint(x: 0, y: end))
        listView.reflectScrolledClipView(listView.contentView)
        let shown = lastRow.convert(lastRow.bounds, to: root)
        #expect(listFrame.contains(shown), "the last row at \(shown) is outside the list at \(listFrame)")
        print("R33 list under request at 390x210: \(scrollViews.count) scroll views, list at \(listFrame), \(rows.count) rows of \(rowHeight), last row scrolled to \(shown)")
    }

    @Test func R33__the_hook_helper_sends_the_claude_process_past_the_hook_shell() async throws {
        // hook shell (500) → claude (400) → login shell (300) → Terminal (100).
        let table = FakeProcessTable(entries: [
            500: ProcessEntry(parent: 400, tty: nil, executablePath: "/bin/sh"),
            450: ProcessEntry(parent: 500, tty: nil, executablePath: "/bin/zsh"),
            400: ProcessEntry(parent: 300, tty: "/dev/ttys004", executablePath: "/Users/me/.local/share/claude/versions/2.1.286"),
            300: ProcessEntry(parent: 100, tty: "/dev/ttys004", executablePath: "/bin/zsh"),
            100: ProcessEntry(parent: 1, tty: nil, executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        ])
        #expect(ClaudeProcess.find(startingAt: 500, in: table) == 400)
        #expect(ClaudeProcess.find(startingAt: 450, in: table) == 400)
        #expect(ClaudeProcess.find(startingAt: 400, in: table) == 400)
        #expect(ClaudeProcess.find(startingAt: 9, in: table) == nil)

        let server = try TestServer()
        defer { server.stop() }
        let runner = HookRunner(
            socketPath: server.path, environment: [:],
            readInput: { Data(#"{"session_id":"s1","cwd":"/Users/me/work/rock-garden","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#.utf8) },
            findTerminal: { ghostty }, findClaudeProcess: { 400 }
        )
        #expect(await run(runner, ["UserPromptSubmit"]).isEmpty)
        let received = await server.inbox.wait(for: 1)
        #expect(received.map(\.event) == [.userPromptSubmit])
        #expect(received.first?.context.claudePID == 400)
    }

    @Test func R33__installer_adds_the_session_hooks_and_reads_an_older_install_as_partial() throws {
        let home = try makeDirectory("agents-home")
        let settings = home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let helper = URL(fileURLWithPath: "/Applications/NotchTheRock.app/Contents/PlugIns/Agents.notchplugin/Contents/Helpers/notch-hook")
        let entries = HookEntry.claude(helper: helper)
        func installer(_ entries: [HookEntry]) -> HookInstaller {
            HookInstaller(settingsURL: settings, recordURL: home.appendingPathComponent("storage/claude-install.json"), entries: entries)
        }
        for event in [HookEvent.userPromptSubmit, .sessionEnd, .postToolUse, .postToolUseFailure] {
            let entry = try #require(entries.first { $0.event == event.rawValue })
            #expect(entry.matcher == nil && entry.timeout == 10 && entry.command == HookInstaller.command(helper: helper, event: event))
        }
        // What earlier versions installed: before the session hooks, before PostToolUse, and before
        // PostToolUseFailure.
        try installer(entries.filter { !["UserPromptSubmit", "SessionEnd", "PostToolUse", "PostToolUseFailure"].contains($0.event) }).install()
        #expect(installer(entries).status() == .partial)
        try installer(entries.filter { $0.event != "PostToolUse" && $0.event != "PostToolUseFailure" }).install()
        #expect(installer(entries).status() == .partial)
        try installer(entries.filter { $0.event != "PostToolUseFailure" }).install()
        #expect(installer(entries).status() == .partial)

        try installer(entries).install()
        #expect(installer(entries).status() == .installed)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        func commands(_ event: String) -> [String] {
            (hooks[event] as? [[String: Any]] ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        }
        #expect(commands("UserPromptSubmit") == [HookInstaller.command(helper: helper, event: .userPromptSubmit)])
        #expect(commands("SessionEnd") == [HookInstaller.command(helper: helper, event: .sessionEnd)])
        #expect(commands("PostToolUse") == [HookInstaller.command(helper: helper, event: .postToolUse)])
        #expect(commands("PostToolUseFailure") == [HookInstaller.command(helper: helper, event: .postToolUseFailure)])
        #expect(commands("Stop").count == 1 && commands("SessionStart").count == 1)
    }

    @Test func R33__session_rows_show_the_logo_folder_and_state() throws {
        // The rows count the time from now, as the screen does.
        world.now = .now - 240
        let logos = FakeLogos()
        // Drawn black: only a template tinted to the row's foreground shows on the notch.
        logos.images[.claude] = solidLogo(.black, template: true)
        bridge.receive(try message(.sessionStart))
        world.now += 1
        bridge.receive(try message(.userPromptSubmit, session: "s2"))
        list.update(AgentSession.Key(agent: .claude, id: "s2"), folder: "tide-pool", state: .working)
        let rows = list.sessions
        #expect(rows.map(\.folder) == ["tide-pool", "rock-garden"])
        #expect(rows.map(\.state.title) == ["작업 중", "대기 중"])
        #expect(AgentSession.elapsed(since: world.now, now: world.now + 30) == "방금")
        #expect(AgentSession.elapsed(since: world.now, now: world.now + 180) == "3분")
        #expect(AgentSession.elapsed(since: world.now, now: world.now + 7_300) == "2시간")

        let screen = AgentsScreen(model: bridge.screen, logos: logos)
        let ideal = NSHostingView(rootView: screen).fittingSize
        let view = layOut(screen, in: CGSize(width: ideal.width + 80, height: ideal.height))
        try capture(view, named: "R33-render-claude-T113")
        print("R33 sessions ideal \(ideal)")
        // The first row's mark, tinted white.
        let mark = CGRect(x: 3, y: 3, width: 10, height: 10)
        let white = try share(of: mark, in: view) { r, g, b in min(r, g, b) > 200 }
        #expect(white > 0.8, "the logo is not drawn in the row's foreground: \(white)")
        // The rows run across a wider offer: ink reaches its right edge (the time).
        let right = try share(of: CGRect(x: ideal.width + 80 - 12, y: 0, width: 12, height: ideal.height), in: view) { r, g, b in max(r, g, b) > 40 }
        #expect(right > 0, "the rows do not reach the right edge")

        // Without a logo the row shows a symbol and the agent's name instead.
        let withLogo = NSHostingView(rootView: AgentSessionRow(session: rows[0], logo: logos.images[.claude], open: { _ in })).fittingSize
        let fallback = NSHostingView(rootView: AgentSessionRow(session: rows[0], logo: nil, open: { _ in })).fittingSize
        #expect(fallback.width - withLogo.width > 20, "no agent name beside the symbol: \(fallback) vs \(withLogo)")
        try capture(AgentsScreen(model: bridge.screen).frame(width: 320).background(.black), named: "R33-render-fallback-T113")
    }

    @Test func R33__a_row_opens_its_sessions_terminal() throws {
        let paths = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: paths.folder) }
        let directory = try makeDirectory()
        let plugin = AgentsPlugin(
            context: try makeContext(host: host, directory: directory),
            socketPath: paths.socket,
            settingsURL: directory.appendingPathComponent("settings.json"),
            claudeExecutable: nil,
            activator: activator,
            codexEndpoint: CodexEndpoint(home: directory),
            codexExecutable: nil,
            codexLauncher: FakeLauncher(socketPath: ""),
            codexTerminal: { _ in nil }
        )
        let terminal = TerminalLocation(bundleID: "com.apple.Terminal", tty: "/dev/ttys007")
        plugin.open(AgentSession(id: key, folder: "rock-garden", state: .idle, changed: world.now, terminal: terminal))
        plugin.open(AgentSession(id: key, folder: "rock-garden", state: .idle, changed: world.now, terminal: nil))
        #expect(activator.activated == [terminal])
        activator.succeeds = false
        plugin.open(AgentSession(id: key, folder: "rock-garden", state: .idle, changed: world.now, terminal: terminal))
        #expect(host.logs.contains { $0.contains("not running") })
    }
}
