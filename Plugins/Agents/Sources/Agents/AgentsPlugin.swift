import HookBridge
import NotchKit
import SwiftUI

/// Brings Claude Code to the notch. Claude Code's hooks run the bundled `notch-hook` helper, which
/// forwards each hook to this plugin over a Unix socket in a folder only the user can enter. When a
/// session waits for input, finishes its turn or ends, the notch glows with the agent's mark, the
/// project name and the message, and from there the user jumps to the session's terminal. Permission requests are allowed
/// or denied, and AskUserQuestion answered, in the notch; "터미널에서 답하기" or the end of the wait
/// hands them back to the terminal. An operation too long for the notch, and typed answers to several
/// questions, are shown in full on the plugin's screen and answered there. The settings page
/// declares what the plugin uses and the wait, and its own rows install and remove the hooks in
/// `~/.claude/settings.json`; the onboarding's setup step connects the same way (`AgentSetup`).
@MainActor
public final class AgentsPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.agents",
        name: "코딩 에이전트",
        version: "1.0.0",
        symbol: "terminal.fill",
        sdkVersion: NotchKitSDK.version
    )

    let bridge: ClaudeBridge
    let hooks: ClaudeHooksModel
    let codexBridge: CodexBridge
    let codexLink: CodexLink
    let codex: CodexModel
    /// Codex sessions the bridge does not follow, the desktop app's among them, read from their rollouts.
    let rollouts: CodexRollouts
    private let context: NotchContext
    /// Whether a `claude` executable was found at launch; without one the onboarding card says so.
    private let claudeInstalled: Bool
    private let socketPath: String
    private let activator: any TerminalActivating
    private let logos: InstalledAppLogos
    private var isActive = false
    private var server: HookServer?
    /// Drops ended sessions from the list while the plugin is active.
    private var pruning: Task<Void, Never>?

    public convenience init(context: NotchContext) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            context: context,
            socketPath: HookSocket.defaultPath(home: home),
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            claudeExecutable: ToolSearch.find(candidates: ToolSearch.candidates(
                named: "claude",
                home: home,
                extraFolders: [home.appendingPathComponent(".claude/local").path]
            )),
            activator: SystemTerminalActivator(log: { [log = context.log] in log.error($0) }),
            codexEndpoint: .current(home: home),
            codexExecutable: ToolSearch.find(candidates: ToolSearch.candidates(named: "codex", home: home)),
            codexLauncher: SystemCodexLauncher(),
            codexTerminal: CodexTerminals.systemTerminal(forCwd:)
        )
    }

    init(
        context: NotchContext,
        socketPath: String,
        settingsURL: URL,
        claudeExecutable: URL?,
        activator: any TerminalActivating,
        codexEndpoint: CodexEndpoint,
        codexExecutable: URL?,
        codexLauncher: any CodexLaunching,
        codexTerminal: @escaping @MainActor (String?) -> TerminalLocation?
    ) {
        self.context = context
        self.socketPath = socketPath
        claudeInstalled = claudeExecutable != nil
        self.activator = activator
        let logos = InstalledAppLogos()
        self.logos = logos
        let defaults = context.storage.defaults
        ApprovalWait.migrate(defaults)
        let settings = context.settings
        bridge = ClaudeBridge(context: context, activator: activator, logos: logos) {
            .seconds(ApprovalWait.seconds(in: settings))
        }
        hooks = ClaudeHooksModel(installer: HookInstaller(
            settingsURL: settingsURL,
            recordURL: context.storage.directory.appendingPathComponent("claude-install.json"),
            entries: HookEntry.claude(helper: context.bundleURL.appendingPathComponent("Contents/Helpers/notch-hook"))
        ))
        let codexBridge = CodexBridge(context: context, activator: activator, screen: bridge.screen, terminal: codexTerminal, logos: logos) {
            .seconds(ApprovalWait.seconds(in: settings))
        }
        let link = CodexLink(
            supervisor: CodexSupervisor(endpoint: codexEndpoint, executable: codexExecutable, launcher: codexLauncher),
            bridge: codexBridge,
            log: { [log = context.log] in log.error($0) }
        )
        let rollouts = CodexRollouts(
            root: codexEndpoint.home.appendingPathComponent("sessions"), context: context, bridge: codexBridge,
            activator: activator, logos: logos
        )
        // The rollouts follow the same switch as the bridge.
        let codex = CodexModel(
            defaults: defaults, executable: codexExecutable,
            start: { link.start(); rollouts.start() }, stop: { link.stop(); rollouts.stop() }
        )
        // The plugin owns the model and the link; the model's closures own the link, so the link
        // must not own the model back.
        link.onState = { [weak codex] in codex?.state = $0 }
        self.codexBridge = codexBridge
        codexLink = link
        self.rollouts = rollouts
        self.codex = codex
    }

    public func activate() {
        guard !isActive else { return }
        isActive = true
        pruning = Task { [sessions = bridge.screen.sessions] in
            while !Task.isCancelled {
                try? await Task.sleep(for: AgentSessionList.pruneInterval)
                sessions.prune()
            }
        }
        let bridge = bridge
        let log = context.log
        let server = HookServer(
            path: socketPath,
            log: { message in Task { @MainActor in log.error(message) } },
            handler: { message, reply in Task { @MainActor in bridge.handle(message, reply: reply) } }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            // Hooks find no socket and leave Claude Code as it is; activating after the next
            // deactivate() tries again.
            log.error("The Claude Code socket is not available: \(error)")
        }
        if codex.enabled {
            codexLink.start()
            rollouts.start()
        }
    }

    public func deactivate() {
        guard isActive else { return }
        server?.stop()
        server = nil
        pruning?.cancel()
        pruning = nil
        bridge.cancelAll()
        codexLink.stop()
        rollouts.stop()
        codexBridge.cancelAll()
        // Events stop while the plugin is off; each session returns with its next one.
        bridge.screen.sessions.removeAll()
        isActive = false
    }

    /// Brings the terminal of a session on the Agents screen forward and folds the notch; a session
    /// without a known or running terminal leaves the notch as it is.
    func open(_ session: AgentSession) {
        guard let terminal = session.terminal, !activator.jump(to: terminal, collapsing: context) else { return }
        context.log.error("The terminal of \(session.agent.name) session \(session.folder) is not running.")
    }

    /// Requests too long for the notch, shown in full where they are answered, and the open sessions.
    public var expandedTab: PluginTab? {
        PluginTab(title: Self.manifest.name, symbol: Self.manifest.symbol) { [screen = bridge.screen, logos] in
            AgentsScreen(model: screen, logos: logos) { [weak self] in self?.open($0) }
        }
    }

    /// Wide: the open sessions, those waiting for the user first. Small: how many are open and wait.
    /// Tapping it opens the screen.
    public var tile: PluginTile? {
        PluginTile(supportedSizes: [.wide, .small]) { [sessions = bridge.screen.sessions, logos] size in
            AgentsTile(sessions: sessions, logos: logos, size: size)
        }
    }

    /// Connecting Claude Code and Codex does not fit a declared item, so those rows stay the plugin's own.
    public var settingsView: AnyView? {
        AnyView(AgentsSettingsView(model: hooks, codex: codex))
    }

    public var pluginDescription: PluginDescription? {
        PluginDescription(
            summary: "Claude Code와 Codex 세션이 입력을 기다리거나 작업을 마치면 노치에 알려 줘요. 권한 요청과 질문에는 노치에서 바로 답할 수 있어요.",
            permissions: [
                PluginPermission(.otherAppSettings(app: "Claude Code"), reason: "연결하면 ~/.claude/settings.json을 같은 폴더에 백업한 뒤 알림 훅을 더하고, 해제하면 더한 훅만 지워요."),
                PluginPermission(.files(path: "~/.claude/projects/*"), reason: "세션마다 context 사용량을 보여 주려고 Claude Code 대화 기록을 읽어요."),
                PluginPermission(.files(path: "$CODEX_HOME/sessions"), reason: "Codex 데스크톱 앱 세션을 목록과 알림에 보여 주려고 기록 파일을 읽어요."),
                PluginPermission(.helperProcesses, reason: "Claude Code 훅이 함께 담긴 notch-hook을 실행해요. Codex를 연결하면 떠 있는 공유 app-server를 쓰고, 없으면 codex app-server를 직접 띄워요."),
                PluginPermission(.automation(app: "터미널"), reason: "터미널로 이동할 때 세션이 열린 탭을 고르려고 터미널에 Apple Events를 보내요."),
            ],
            settings: [ApprovalWait.item]
        )
    }

    public var setup: PluginSetup? {
        AgentSetup.make(hooks: hooks, claudeInstalled: claudeInstalled, codex: codex, logos: logos)
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(AgentsPlugin.self)
}
