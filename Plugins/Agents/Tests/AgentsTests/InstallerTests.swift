import Foundation
import HookBridge
import Testing
@testable import Agents

/// The installer works on a settings file in a temporary folder, never on ~/.claude.
@Suite struct InstallerTests {
    let directory: URL
    let settings: URL
    let record: URL
    let helper = URL(fileURLWithPath: "/Applications/NotchTheRock.app/Contents/PlugIns/Agents.notchplugin/Contents/Helpers/notch-hook")

    init() throws {
        directory = try makeDirectory("agents-installer")
        settings = directory.appendingPathComponent(".claude/settings.json")
        record = directory.appendingPathComponent("storage/claude-install.json")
        try FileManager.default.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func installer(helper: URL? = nil, at settings: URL? = nil) -> HookInstaller {
        HookInstaller(
            settingsURL: settings ?? self.settings,
            recordURL: record,
            entries: HookEntry.claude(helper: helper ?? self.helper),
            now: { Date(timeIntervalSince1970: 1_790_000_000) }
        )
    }

    func write(_ text: String, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: settings.path)
    }

    func settingsObject() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    }

    /// Every hook command in the settings file under `event`, in order.
    func commands(_ event: String) throws -> [String] {
        let hooks = try settingsObject()["hooks"] as? [String: Any]
        let groups = hooks?[event] as? [[String: Any]] ?? []
        return groups.flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
    }

    func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: settings.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("settings.json.notchtherock-") }
    }

    static let otherHooks = """
    {
        "model": "opus",
      "hooks": {
        "Stop": [ { "hooks": [ { "type": "command", "command": "afplay /System/Library/Sounds/Glass.aiff" } ] } ],
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type":"command","command":"/usr/local/bin/guard"}]}]
      },
      "env": {"FOO": "bar"}
    }

    """

    @Test func R05__install_merges_beside_other_hooks_and_uninstall_restores_the_bytes() throws {
        try write(Self.otherHooks)
        let original = try Data(contentsOf: settings)
        let installer = installer()

        try installer.install()
        #expect(installer.status() == .installed)
        let object = try settingsObject()
        #expect(object["model"] as? String == "opus")
        #expect(object["env"] as? [String: String] == ["FOO": "bar"])
        let stop = HookInstaller.command(helper: helper, event: .stop)
        #expect(try commands("Stop") == ["afplay /System/Library/Sounds/Glass.aiff", stop])
        #expect(try commands("PreToolUse") == ["/usr/local/bin/guard", HookInstaller.command(helper: helper, event: .preToolUse)])
        #expect(try commands("PermissionRequest") == [HookInstaller.command(helper: helper, event: .permissionRequest)])
        #expect(try commands("SessionStart") == [HookInstaller.command(helper: helper, event: .sessionStart)])
        #expect(try commands("Notification") == [HookInstaller.command(helper: helper, event: .notification)])
        let mode = try FileManager.default.attributesOfItem(atPath: settings.path)[.posixPermissions] as? Int
        #expect(mode == 0o644)

        #expect(try installer.uninstall() == .restored)
        #expect(try Data(contentsOf: settings) == original)
        #expect(installer.status() == .notInstalled)
    }

    @Test func R05__uninstall_deletes_the_file_install_created() throws {
        let installer = installer()
        try installer.install()
        #expect(try commands("Stop") == [HookInstaller.command(helper: helper, event: .stop)])
        #expect(try backups().isEmpty)

        #expect(try installer.uninstall() == .deleted)
        #expect(!FileManager.default.fileExists(atPath: settings.path))
    }

    @Test func R05__restore_keeps_comments_and_odd_formatting() throws {
        try write("""
        // my settings
        {
          /* theme */ "theme": "dark",
          "permissions": { "allow": ["Bash(ls:*)",], },
        }
        """)
        let original = try Data(contentsOf: settings)
        let installer = installer()

        try installer.install()
        #expect(try settingsObject()["theme"] as? String == "dark")
        #expect(try installer.uninstall() == .restored)
        #expect(try Data(contentsOf: settings) == original)
    }

    @Test func R05__uninstall_after_an_edit_removes_only_our_entries() throws {
        try write(Self.otherHooks)
        let installer = installer()
        try installer.install()
        var object = try settingsObject()
        object["theme"] = "dark"
        try JSONSerialization.data(withJSONObject: object).write(to: settings)

        #expect(try installer.uninstall() == .removedEntries)
        let after = try settingsObject()
        #expect(after["theme"] as? String == "dark")
        #expect(after["model"] as? String == "opus")
        #expect(try commands("Stop") == ["afplay /System/Library/Sounds/Glass.aiff"])
        #expect(try commands("PreToolUse") == ["/usr/local/bin/guard"])
        let hooks = try #require(after["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["Stop", "PreToolUse"])
        #expect(installer.status() == .notInstalled)
    }

    @Test func R05__backup_is_a_private_copy_of_the_previous_file() throws {
        try write(Self.otherHooks)
        let original = try Data(contentsOf: settings)
        try installer().install()

        let backup = try #require(try backups().first)
        #expect(try backups().count == 1)
        #expect(try Data(contentsOf: backup) == original)
        let mode = try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test(arguments: ["{ \"hooks\": [", "{\"hooks\": []}", "[1, 2]", ""])
    func R05__unreadable_settings_are_left_untouched(_ text: String) throws {
        try write(text)
        let original = try Data(contentsOf: settings)
        let installer = installer()

        #expect(throws: InstallError.self) { try installer.install() }
        #expect(try Data(contentsOf: settings) == original)
        #expect(try backups().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: record.path))
        guard case .unreadable(let reason) = installer.status() else {
            Issue.record("status should say the file is unreadable")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test func R05__installing_twice_adds_each_entry_once() throws {
        try write(Self.otherHooks)
        let original = try Data(contentsOf: settings)
        let installer = installer()
        try installer.install()
        try installer.install()

        #expect(try commands("Stop").count == 2)
        #expect(try commands("SessionStart").count == 1)
        #expect(try installer.uninstall() == .restored)
        #expect(try Data(contentsOf: settings) == original)
    }

    @Test func R05__a_symlinked_settings_file_stays_a_link() throws {
        let target = directory.appendingPathComponent("dotfiles/claude-settings.json")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.otherHooks.utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: target)
        let installer = installer()

        try installer.install()
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path) == target.path)
        #expect(try commands("Stop").count == 2)
        #expect(try installer.uninstall() == .restored)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: settings.path) == target.path)
        #expect(try Data(contentsOf: target) == Data(Self.otherHooks.utf8))
    }

    @Test func R05__installed_command_runs_from_a_path_with_a_space() throws {
        let helpers = directory.appendingPathComponent("Application Support/Agents.notchplugin/Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let hook = helpers.appendingPathComponent("notch-hook")
        try FileManager.default.copyItem(at: builtHook, to: hook)
        try installer(helper: hook).install()
        let command = try #require(try commands("Stop").first)

        let socket = makeSocketPath()
        let result = try runProcess(
            URL(fileURLWithPath: "/bin/sh"), ["-c", command],
            input: Data(#"{"session_id":"s1","hook_event_name":"Stop"}"#.utf8),
            environment: [HookSocket.pathEnvironmentKey: socket.socket]
        )
        #expect(result.status == 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }
}
