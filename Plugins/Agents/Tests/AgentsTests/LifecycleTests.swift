import Darwin
import Foundation
import HookBridge
import NotchKit
import Testing
@testable import Agents

/// The plugin's `activate()` and `deactivate()`: one activation starts one hook server, one Codex
/// link and one rollout poll, however often it is asked; `deactivate()` stops them and removes the
/// hook socket; the next `activate()` serves the socket again. The hook socket and the codex home are
/// short temporary paths and codex is the fake launcher, so nothing touches ~/.claude or ~/.codex.
@MainActor
@Suite struct LifecycleTests {
    let host = FakeHost()
    let paths = makeSocketPath()
    let codexHome = URL(fileURLWithPath: makeShortPath())
    let directory: URL
    let launcher: FakeLauncher

    init() throws {
        directory = try makeDirectory()
        launcher = FakeLauncher(socketPath: CodexEndpoint(home: codexHome).socketPath)
    }

    /// The plugin with Codex connected in an earlier launch, so `activate()` starts the link too.
    private func plugin() throws -> AgentsPlugin {
        let context = try makeContext(host: host, directory: directory)
        context.storage.defaults.set(true, forKey: CodexModel.enabledKey)
        return makePlugin(
            context: context,
            directory: directory,
            socketPath: paths.socket,
            codexEndpoint: CodexEndpoint(home: codexHome),
            codexExecutable: codexHome.appendingPathComponent("codex"),
            codexLauncher: launcher
        )
    }

    private func cleanUp(_ plugin: AgentsPlugin) {
        plugin.deactivate()
        launcher.listeners.forEach { close($0) }
        try? FileManager.default.removeItem(atPath: paths.folder)
        try? FileManager.default.removeItem(at: codexHome)
    }

    /// Sends a Stop hook through the socket, as the helper does.
    private func sendStop() async {
        let runner = HookRunner(
            socketPath: paths.socket,
            environment: [:],
            readInput: { Data(#"{"session_id":"s9","cwd":"/Users/me/proj","hook_event_name":"Stop"}"#.utf8) },
            findTerminal: { ghostty }
        )
        _ = await run(runner, ["Stop"])
    }

    @Test func R64__activating_twice_starts_one_hook_server_one_codex_link_and_one_rollout_poll() async throws {
        let plugin = try plugin()
        defer { cleanUp(plugin) }
        plugin.activate()
        plugin.activate()
        #expect(await eventually { launcher.launches.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(launcher.launches.count == 1, "codex app-server launched \(launcher.launches.count) times")
        await sendStop()
        #expect(await eventually { !host.requests.isEmpty })
        #expect(host.requests.map(\.title) == ["proj"])
    }

    /// A socket the plugin cannot open is tried once per activation, not once per call.
    @Test func R64__activating_twice_tries_an_unavailable_hook_socket_once() throws {
        // A file where the socket folder should be: the server refuses to start.
        try Data().write(to: URL(fileURLWithPath: paths.folder))
        let plugin = try plugin()
        defer { cleanUp(plugin) }
        plugin.activate()
        plugin.activate()
        let refusals = host.logs.filter { $0.contains("The Claude Code socket is not available") }
        #expect(refusals.count == 1, "\(host.logs)")
    }

    @Test func R64__deactivate_stops_the_hook_server_and_codex_and_removes_the_socket() async throws {
        let plugin = try plugin()
        defer { cleanUp(plugin) }
        plugin.activate()
        #expect(await eventually { launcher.processes.count == 1 })
        #expect(FileManager.default.fileExists(atPath: paths.socket))
        plugin.bridge.screen.sessions.update(AgentSession.Key(agent: .claude, id: "s1"), folder: "proj", state: .idle)

        plugin.deactivate()
        #expect(!FileManager.default.fileExists(atPath: paths.socket))
        #expect(plugin.codex.state == .off)
        #expect(launcher.processes.allSatisfy { $0.terminated }, "the codex app-server the plugin started still runs")
        #expect(plugin.bridge.screen.sessions.sessions.isEmpty)
        // Nothing listens any more: a hook finds no socket and the notch is not asked.
        await sendStop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(host.requests.isEmpty)
    }

    @Test func R64__activate_after_deactivate_serves_the_hook_socket_again() async throws {
        let plugin = try plugin()
        defer { cleanUp(plugin) }
        plugin.activate()
        plugin.deactivate()
        plugin.activate()
        #expect(FileManager.default.fileExists(atPath: paths.socket))
        #expect(await eventually { plugin.codex.state != .off }, "the Codex link did not start again")
        await sendStop()
        #expect(await eventually { !host.requests.isEmpty })
        #expect(host.requests.map(\.title) == ["proj"])
    }
}
