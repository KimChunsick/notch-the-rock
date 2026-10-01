import Observation
import SwiftUI

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

/// 연결 adds the plugin's hooks to `~/.claude/settings.json` after backing it up; 해제 takes them out.
/// The wait applies to the next request.
struct AgentsSettingsView: View {
    /// codex's TUI keeps its own prompt while the notch waits; Claude Code's terminal holds its question back.
    static let waitNote = "권한 요청과 질문에 이 시간 안에 답하지 않으면 터미널에서 이어서 답해요. Claude Code의 질문은 기다리는 동안 터미널에 나타나지 않아요."

    /// When the notch glows for a session, and every case where it intentionally does not.
    static let alertNote = "Claude Code가 입력을 기다리거나 작업을 마치거나 세션이 끝날 때, Codex가 작업을 마치거나 오류로 멈추거나 세션이 끝날 때 노치에 알림이 떠요. 작업을 마쳤다고 알린 뒤 같은 멈춤에서 다시 오는 입력 대기 알림, 권한 요청 알림(요청이 노치에 바로 떠요), 터미널에서 직접 멈춘 Codex 작업은 따로 알리지 않아요. 한 세션에 새 알림이 오면 이전 알림을 대신해요. 알림은 30초 뒤에 사라지고, 다른 요청이 노치에 떠 있어 뒤에서 기다리는 동안에도 이 시간은 흘러요."

    let model: ClaudeHooksModel
    let codex: CodexModel
    @AppStorage private var wait: Int

    init(model: ClaudeHooksModel, codex: CodexModel, defaults: UserDefaults) {
        self.model = model
        self.codex = codex
        _wait = AppStorage(wrappedValue: ApprovalWait.defaultSeconds, ApprovalWait.defaultsKey, store: defaults)
    }

    var body: some View {
        Group {
            LabeledContent {
                HStack {
                    Button("연결") { model.install() }
                        .disabled(!canInstall)
                    Button("해제") { model.uninstall() }
                        .disabled(!canUninstall)
                }
            } label: {
                Text("Claude Code")
                Text(statusText)
            }
            if let problem = model.problem {
                Text(problem)
                    .foregroundStyle(.red)
            }
            if let notice = model.notice {
                Text(notice)
                    .foregroundStyle(.orange)
            }
            Text("연결하면 ~/.claude/settings.json을 같은 폴더에 백업한 뒤 NotchTheRock 훅을 더해요. 해제하면 더한 훅만 지우고, 그사이 파일이 바뀌지 않았다면 연결하기 전 파일로 그대로 되돌려요.")
                .font(.callout)
                .foregroundStyle(.secondary)
            codexSection
            Text(Self.alertNote)
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker(selection: $wait) {
                ForEach(ApprovalWait.choices, id: \.self) { seconds in
                    Text(ApprovalWait.title(seconds)).tag(seconds)
                }
            } label: {
                Text("노치에서 기다리는 시간")
                Text(Self.waitNote)
            }
        }
        .onAppear { model.refresh() }
    }

    @ViewBuilder
    private var codexSection: some View {
        LabeledContent {
            HStack {
                Button("연결") { codex.connect() }
                    .disabled(codex.enabled || codex.executable == nil)
                Button("해제") { codex.disconnect() }
                    .disabled(!codex.enabled)
            }
        } label: {
            Text("Codex")
            Text(Self.status(of: codex.state))
        }
        if let install = codex.install {
            Text("codex 위치: \(install.executable.path) · 버전: \(install.version ?? "알 수 없음")")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let warning = install.warning {
                Text(warning)
                    .foregroundStyle(.orange)
            }
        } else if let executable = codex.executable {
            Text("codex 위치: \(executable.path) · 버전을 확인하고 있어요.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .task { await codex.checkVersion() }
        } else {
            Text("codex를 찾지 못했어요. codex를 설치한 뒤 앱을 다시 열어 주세요.")
                .foregroundStyle(.orange)
        }
        Text("연결하면 $CODEX_HOME/app-server-control/app-server-control.sock에 떠 있는 공유 app-server를 쓰고, 없으면 노치가 직접 띄워요. app-server가 뜨기 전에 시작한 codex 세션은 노치에 보이지 않아요. 해제하면 노치가 띄운 app-server만 멈춰요.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    static func status(of state: CodexLink.State) -> String {
        switch state {
        case .off: "연결하지 않았어요. 연결하면 Codex가 작업을 마치거나 승인과 답을 기다릴 때 노치가 알려 줘요."
        case .connecting: "app-server에 연결하고 있어요."
        case .connected(.reused): "연결했어요. 이미 떠 있던 app-server를 함께 쓰고 있어요."
        case .connected(.spawned): "연결했어요. 노치가 띄운 app-server를 쓰고 있어요."
        case .incomplete(_, let reason): "연결했지만 \(reason) 해제한 뒤 다시 연결하면 세션을 다시 찾아요."
        case .retrying(let reason): "연결하지 못해서 잠시 뒤 다시 시도해요. \(reason)"
        }
    }

    private var canInstall: Bool {
        model.status == .notInstalled || model.status == .partial
    }

    private var canUninstall: Bool {
        model.status == .installed || model.status == .partial
    }

    private var statusText: String {
        switch model.status {
        case .notInstalled: "연결하지 않았어요. 연결하면 Claude Code가 작업을 마치거나 입력을 기다릴 때 노치가 알려 줘요."
        case .installed: "연결했어요. Claude Code가 작업을 마치거나 입력을 기다리면 노치가 알려 줘요."
        case .partial: "훅 일부만 연결돼 있어요. 연결을 누르면 빠진 훅을 더해요."
        case .unreadable(let message): message
        }
    }
}
