import Observation
import SwiftUI

/// The Claude Code connection shown in the settings page.
@MainActor
@Observable
final class ClaudeHooksModel {
    private(set) var status: InstallStatus
    /// Why the last 연결 or 해제 failed, until the next one succeeds.
    private(set) var problem: String?
    private let installer: HookInstaller

    init(installer: HookInstaller) {
        self.installer = installer
        status = installer.status()
    }

    func refresh() {
        status = installer.status()
    }

    func install() {
        perform { () throws(InstallError) in try installer.install() }
    }

    func uninstall() {
        perform { () throws(InstallError) in try installer.uninstall() }
    }

    private func perform(_ change: () throws(InstallError) -> Void) {
        do {
            try change()
            problem = nil
        } catch {
            problem = error.message
        }
        refresh()
    }
}

/// 연결 adds the plugin's hooks to `~/.claude/settings.json` after backing it up; 해제 takes them out.
struct AgentsSettingsView: View {
    let model: ClaudeHooksModel

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
            Text("연결하면 ~/.claude/settings.json을 같은 폴더에 백업한 뒤 NotchTheRock 훅을 더해요. 해제하면 더한 훅만 지우고, 그사이 파일이 바뀌지 않았다면 연결하기 전 파일로 그대로 되돌려요.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .onAppear { model.refresh() }
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
