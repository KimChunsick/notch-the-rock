import Foundation
import NotchKit
import SwiftUI

/// The onboarding's 코딩 에이전트 연결 step: a card for Claude Code and one for Codex. Each card's
/// 연결 is the settings page's 연결 (`ClaudeHooksModel.install()`, `CodexModel.connect()`, after 해제
/// for a Codex connection that lost sessions), and each card shows what the settings page shows,
/// plus whether the tool is installed at all.
@MainActor
enum AgentSetup {
    static let notInstalled = "설치되지 않았어요"

    static func make(hooks: ClaudeHooksModel, claudeInstalled: Bool, codex: CodexModel, logos: any AgentLogoProviding) -> PluginSetup? {
        PluginSetup(title: "코딩 에이전트 연결", message: "에이전트가 일을 마치거나 기다리면 노치가 알려 줘요.", items: [
            PluginSetupItem(
                id: "claude-code",
                title: "Claude Code",
                detail: "settings.json을 백업한 뒤 노치 훅을 더해요",
                icon: AgentKind.claude.alertIcon(logos),
                state: { claudeState(hooks, installed: claudeInstalled) },
                perform: { hooks.install() }
            ),
            PluginSetupItem(
                id: "codex",
                title: "Codex",
                detail: "공유 app-server로 Codex 세션을 노치에 보여줘요",
                icon: AgentKind.codex.alertIcon(logos),
                state: { codexState(codex) },
                perform: { connectCodex(codex) }
            ),
        ])
    }

    /// The settings page offers 연결 while the hooks are missing or partial; an unreadable settings
    /// file is shown as the failure it is.
    static func claudeState(_ hooks: ClaudeHooksModel, installed: Bool) -> PluginSetupState {
        guard installed else { return .unavailable(reason: notInstalled) }
        switch hooks.status {
        case .installed: return .connected
        case .unreadable(let message): return .failed(message: message)
        case .notInstalled, .partial: return hooks.problem.map { .failed(message: $0) } ?? .notConnected
        }
    }

    /// Connected once the user connected Codex and the app-server answered. While the connection
    /// tries again by itself the card works with the settings page's text and offers no button; a
    /// connection that lost sessions is a failure with the settings page's explanation.
    static func codexState(_ codex: CodexModel) -> PluginSetupState {
        guard codex.executable != nil else { return .unavailable(reason: notInstalled) }
        guard codex.enabled else { return .notConnected }
        switch codex.state {
        case .off, .connecting: return .working(message: nil)
        case .connected: return .connected
        case .retrying: return .working(message: AgentsSettingsView.status(of: codex.state))
        case .incomplete: return .failed(message: AgentsSettingsView.status(of: codex.state))
        }
    }

    /// The settings page's 연결, after its 해제 when Codex is connected already: the card offers its
    /// button then only for a connection that lost sessions, and connecting again while the link
    /// runs does nothing.
    static func connectCodex(_ codex: CodexModel) {
        if codex.enabled { codex.disconnect() }
        codex.connect()
    }
}
