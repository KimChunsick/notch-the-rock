import Observation

/// The Claude Code connection shown in the settings page.
@MainActor
@Observable
final class ClaudeHooksModel {
    private(set) var status: InstallStatus
    /// Why the last 연결 or 해제 failed, until the next one succeeds.
    private(set) var problem: String?
    /// What the last 해제 could not do, such as putting the file back byte for byte.
    private(set) var notice: String?
    private let installer: HookInstaller

    init(installer: HookInstaller) {
        self.installer = installer
        status = installer.status()
    }

    func refresh() {
        status = installer.status()
    }

    func install() {
        perform { () throws(InstallError) -> String? in
            try installer.install()
            return nil
        }
    }

    func uninstall() {
        perform { () throws(InstallError) -> String? in try installer.uninstall().message }
    }

    /// Runs `change`, which returns what the user should know when it went through.
    private func perform(_ change: () throws(InstallError) -> String?) {
        do {
            notice = try change()
            problem = nil
        } catch {
            notice = nil
            problem = error.message
        }
        refresh()
    }
}
