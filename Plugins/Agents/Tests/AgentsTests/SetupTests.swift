import Foundation
import NotchKit
import Testing
@testable import Agents

/// The onboarding's 코딩 에이전트 연결 step. Nothing here touches ~/.claude or ~/.codex: the settings
/// file, the plugin's storage and the codex home are in a temporary folder, and codex is a fake.
@MainActor
@Suite struct SetupTests {
    private func plugin(in directory: URL, claude: URL?, codex: URL?) throws -> AgentsPlugin {
        makePlugin(
            context: try makeContext(host: FakeHost(), directory: directory),
            directory: directory,
            socketPath: directory.appendingPathComponent("s").path,
            claudeExecutable: claude,
            codexExecutable: codex
        )
    }

    @Test func R43__tools_that_are_not_installed_are_unavailable() throws {
        let directory = try makeDirectory()
        let plugin = try plugin(in: directory, claude: nil, codex: nil)
        let setup = try #require(plugin.setup)
        #expect(setup.title == "코딩 에이전트 연결")
        #expect(setup.items.map(\.title) == ["Claude Code", "Codex"])
        #expect(setup.items.map(\.state) == [.unavailable(reason: AgentSetup.notInstalled), .unavailable(reason: AgentSetup.notInstalled)])
    }

    /// Each card's 연결 is the settings page's 연결: the same installer with the same backup, and the
    /// same Codex connection, remembered across launches.
    @Test func R43__connect_runs_the_settings_page_connection_and_the_cards_turn_connected() throws {
        let directory = try makeDirectory()
        let settings = directory.appendingPathComponent("settings.json")
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)
        let plugin = try plugin(in: directory, claude: directory.appendingPathComponent("claude"), codex: directory.appendingPathComponent("codex"))
        // Not activated: 연결 below starts the Codex link, and 해제 stops it again.
        defer { plugin.codex.disconnect() }
        let items = try #require(plugin.setup).items
        #expect(items.map(\.state) == [.notConnected, .notConnected])

        items[0].perform()
        #expect(plugin.hooks.status == .installed)
        #expect(items[0].state == .connected)
        #expect(try String(contentsOf: settings, encoding: .utf8).contains("notch-hook"))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings.contains { $0.hasPrefix("settings") && $0 != "settings.json" }, "backed up first: \(siblings)")

        items[1].perform()
        #expect(plugin.codex.enabled)
        #expect(UserDefaults(suiteName: isolatedDefaultsSuite(in: directory))!.bool(forKey: CodexModel.enabledKey))
        #expect(items[1].state != .notConnected)
    }

    @Test func R43__the_cards_mirror_the_settings_page_state() throws {
        let directory = try makeDirectory()
        let installer = HookInstaller(
            settingsURL: directory.appendingPathComponent("settings.json"),
            recordURL: directory.appendingPathComponent("record.json"),
            entries: HookEntry.claude(helper: directory.appendingPathComponent("notch-hook"))
        )
        let hooks = ClaudeHooksModel(installer: installer)
        #expect(AgentSetup.claudeState(hooks, installed: false) == .unavailable(reason: AgentSetup.notInstalled))
        #expect(AgentSetup.claudeState(hooks, installed: true) == .notConnected)
        hooks.install()
        #expect(AgentSetup.claudeState(hooks, installed: true) == .connected)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("settings.json"))
        hooks.refresh()
        guard case .failed = AgentSetup.claudeState(hooks, installed: true) else {
            Issue.record("an unreadable settings file is a failure with its message")
            return
        }

        let defaults = UserDefaults(suiteName: isolatedDefaultsSuite(in: directory))!
        var started = 0
        let codex = CodexModel(defaults: defaults, executable: directory.appendingPathComponent("codex"), start: { started += 1 }, stop: {})
        let missing = CodexModel(defaults: defaults, executable: nil, start: {}, stop: {})
        #expect(AgentSetup.codexState(missing) == .unavailable(reason: AgentSetup.notInstalled))
        #expect(AgentSetup.codexState(codex) == .notConnected)
        codex.connect()
        #expect(started == 1)
        #expect(AgentSetup.codexState(codex) == .working(message: nil))
        codex.state = .connected(.spawned)
        #expect(AgentSetup.codexState(codex) == .connected)
        codex.state = .retrying("app-server가 응답하지 않아요.")
        #expect(AgentSetup.codexState(codex) == .working(message: AgentsSettingsView.status(of: codex.state)))
    }

    /// A connection that lost sessions shows the settings page's explanation as a failure, and its
    /// button reconnects as the settings page's 해제 then 연결 do. While the connection tries again by
    /// itself the card shows the settings page's text and works, with no button to press.
    @Test func R43__codex_incomplete_reconnects_and_retrying_works_without_a_button() throws {
        let directory = try makeDirectory()
        let hooks = ClaudeHooksModel(installer: HookInstaller(
            settingsURL: directory.appendingPathComponent("settings.json"),
            recordURL: directory.appendingPathComponent("record.json"),
            entries: HookEntry.claude(helper: directory.appendingPathComponent("notch-hook"))
        ))
        var started = 0
        var stopped = 0
        let codex = CodexModel(
            defaults: UserDefaults(suiteName: isolatedDefaultsSuite(in: directory))!,
            executable: directory.appendingPathComponent("codex"),
            start: { started += 1 },
            stop: { stopped += 1 }
        )
        let item = try #require(AgentSetup.make(hooks: hooks, claudeInstalled: false, codex: codex, logos: FakeLogos())).items[1]
        item.perform()
        #expect(started == 1 && stopped == 0, "연결")

        codex.state = .retrying("app-server가 응답하지 않아요.")
        #expect(item.state == .working(message: "연결하지 못해서 잠시 뒤 다시 시도해요. app-server가 응답하지 않아요."))

        codex.state = .incomplete(.spawned, "세션 목록을 읽지 못했어요.")
        #expect(item.state == .failed(message: AgentsSettingsView.status(of: codex.state)))
        #expect(AgentsSettingsView.status(of: codex.state).contains("해제한 뒤 다시 연결하면"))
        item.perform()
        #expect(stopped == 1 && started == 2, "해제, then 연결")
        #expect(codex.enabled)
    }

    @Test func R43__claude_is_looked_for_on_path_and_where_the_installers_put_it() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let candidates = ToolSearch.candidates(named: "claude", environment: ["PATH": "/usr/bin:/custom/bin"], home: home, extraFolders: [home.appendingPathComponent(".claude/local").path])
        #expect(candidates == ["/usr/bin/claude", "/custom/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "/Users/someone/.local/bin/claude", "/Users/someone/.claude/local/claude"])
    }
}
