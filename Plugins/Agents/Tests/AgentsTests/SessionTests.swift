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
        for event in [HookEvent.userPromptSubmit, .sessionEnd] {
            let entry = try #require(entries.first { $0.event == event.rawValue })
            #expect(entry.matcher == nil && entry.timeout == 10 && entry.command == HookInstaller.command(helper: helper, event: event))
        }
        // What an earlier version installed.
        try installer(entries.filter { $0.event != "UserPromptSubmit" && $0.event != "SessionEnd" }).install()
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
