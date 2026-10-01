import HookBridge
import NotchKit
import SwiftUI

/// Brings Claude Code to the notch. Claude Code's hooks run the bundled `notch-hook` helper, which
/// forwards each hook to this plugin over a Unix socket in a folder only the user can enter. When a
/// session finishes its turn or waits for input, the notch glows with the project name and the
/// message, and from there the user jumps to the session's terminal. The settings page installs and
/// removes the hooks in `~/.claude/settings.json`.
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
    private let context: NotchContext
    private let socketPath: String
    private var server: HookServer?

    public convenience init(context: NotchContext) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.init(
            context: context,
            socketPath: HookSocket.defaultPath(home: home),
            settingsURL: home.appendingPathComponent(".claude/settings.json"),
            activator: SystemTerminalActivator(log: { [log = context.log] in log.error($0) })
        )
    }

    init(context: NotchContext, socketPath: String, settingsURL: URL, activator: any TerminalActivating) {
        self.context = context
        self.socketPath = socketPath
        bridge = ClaudeBridge(context: context, activator: activator)
        hooks = ClaudeHooksModel(installer: HookInstaller(
            settingsURL: settingsURL,
            recordURL: context.storage.directory.appendingPathComponent("claude-install.json"),
            entries: HookEntry.claude(helper: context.bundleURL.appendingPathComponent("Contents/Helpers/notch-hook"))
        ))
    }

    public func activate() {
        guard server == nil else { return }
        let bridge = bridge
        let log = context.log
        let server = HookServer(
            path: socketPath,
            log: { message in Task { @MainActor in log.error(message) } },
            handler: { message in Task { @MainActor in bridge.receive(message) } }
        )
        do {
            try server.start()
            self.server = server
        } catch {
            // Hooks find no socket and leave Claude Code as it is; the next activation tries again.
            log.error("The Claude Code socket is not available: \(error)")
        }
    }

    public func deactivate() {
        server?.stop()
        server = nil
        bridge.cancelAll()
    }

    public var settingsView: AnyView? {
        AnyView(AgentsSettingsView(model: hooks))
    }
}

/// The C entry symbol the app resolves after loading the bundle. Keep one per plugin.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(AgentsPlugin.self)
}
