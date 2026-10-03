import SwiftUI

/// The plugin's own rows on its settings page: connecting Claude Code and Codex, with their state,
/// and the short notes the declared summary and permissions do not say. 연결 adds the plugin's
/// hooks to `~/.claude/settings.json` after backing it up; 해제 takes them out.
struct AgentsSettingsView: View {
    /// codex's TUI keeps its own prompt while the notch waits; Claude Code's terminal holds its question back.
    static let waitNote = "노치에서 기다리는 시간 안에 답하지 않으면 터미널에서 이어서 답해요. Claude Code의 질문은 기다리는 동안 터미널에 나타나지 않아요."
    /// What the rollout watcher cannot give the desktop app's sessions, and how to get it.
    static let rolloutNote = "Codex 데스크톱 앱 세션은 기록 파일로 따라가서 승인·입력 대기 알림, 노치에서 답하기, 세션 종료 알림이 없어요. 앱이 CODEX_APP_SERVER_USE_LOCAL_DAEMON=1로 공유 app-server를 쓰면 모두 받을 수 있어요."
    /// The cases where the notch intentionally does not glow, and how long an alert stays.
    static let alertNote = "같은 멈춤에서 다시 오는 입력 대기 알림은 띄우지 않고, 한 세션에 새 알림이 오면 이전 알림을 대신해요. 알림은 뜬 뒤 5초가 지나면 사라져요. 뒤에서 기다린 알림도 뜬 때부터 5초를 세요."

    let model: ClaudeHooksModel
    let codex: CodexModel

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
            codexSection
            note(Self.waitNote)
            note(Self.alertNote)
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
            note("codex 위치: \(install.executable.path) · 버전: \(install.version ?? "알 수 없음")")
            if let warning = install.warning {
                Text(warning)
                    .foregroundStyle(.orange)
            }
        } else if let executable = codex.executable {
            note("codex 위치: \(executable.path) · 버전을 확인하고 있어요.")
                .task { await codex.checkVersion() }
        } else {
            Text("codex를 찾지 못했어요. codex를 설치한 뒤 앱을 다시 열어 주세요.")
                .foregroundStyle(.orange)
        }
        note(Self.rolloutNote)
    }

    private func note(_ text: String) -> some View {
        Text(text)
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
