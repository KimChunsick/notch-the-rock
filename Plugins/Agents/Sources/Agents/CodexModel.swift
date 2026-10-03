import Foundation
import Observation

/// The Codex connection shown in the settings page: off until the user connects, remembered across
/// launches. The codex version is read once, when the page first shows it.
@MainActor
@Observable
final class CodexModel {
    static let enabledKey = "codexEnabled"

    private(set) var enabled: Bool
    let executable: URL?
    /// Nil until the version check finished.
    private(set) var install: CodexInstall?
    var state: CodexLink.State = .off
    @ObservationIgnored private let readVersion: (URL) async -> String?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let start: () -> Void
    @ObservationIgnored private let stop: () -> Void

    init(
        defaults: UserDefaults,
        executable: URL?,
        readVersion: @escaping (URL) async -> String? = { await CodexInstall.readVersion($0) },
        start: @escaping () -> Void,
        stop: @escaping () -> Void
    ) {
        self.defaults = defaults
        self.executable = executable
        self.readVersion = readVersion
        self.start = start
        self.stop = stop
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Reads the version of `executable` once; later calls return at once.
    func checkVersion() async {
        guard let executable, install == nil, !checking else { return }
        checking = true
        let version = await readVersion(executable)
        install = CodexInstall(executable: executable, version: version)
    }

    func connect() {
        defaults.set(true, forKey: Self.enabledKey)
        enabled = true
        start()
    }

    func disconnect() {
        defaults.set(false, forKey: Self.enabledKey)
        enabled = false
        stop()
    }
}
