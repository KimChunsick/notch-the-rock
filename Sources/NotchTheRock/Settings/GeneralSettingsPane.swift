import SwiftUI

/// 일반: launch at login, showing the status the system reports, and the global hotkey.
struct GeneralSettingsPane: View {
    var hotkey: GlobalHotkey = .app
    @State private var status = SystemPermissions.loginItemStatus
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Toggle("로그인 시 자동 실행", isOn: Binding(get: { status.isRegistered }, set: { setLaunchAtLogin($0) }))
                LabeledContent("상태") {
                    Text(status.label)
                        .multilineTextAlignment(.trailing)
                }
                if status == .requiresApproval {
                    Button("로그인 항목 설정 열기") { SystemPermissions.openLoginItemsSettings() }
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section {
                HotkeySettingsRow(hotkey: hotkey)
            }
        }
        .formStyle(.grouped)
        // The user can change the login item in System Settings while this pane is open.
        .task {
            while !Task.isCancelled {
                status = SystemPermissions.loginItemStatus
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try SystemPermissions.setLaunchAtLogin(enabled)
            failure = nil
        } catch {
            failure = SystemPermissions.launchAtLoginFailure(enabling: enabled, error)
        }
        status = SystemPermissions.loginItemStatus
    }
}

/// 권한: whether the app is trusted for Accessibility, with a button that shows the system prompt.
struct PermissionSettingsPane: View {
    @State private var trusted = SystemPermissions.isAccessibilityTrusted

    var body: some View {
        Form {
            Section {
                LabeledContent("손쉬운 사용") {
                    Text(trusted ? "허용됨" : "허용 안 됨")
                        .foregroundStyle(trusted ? Color.secondary : Color.orange)
                }
                Text("키 입력을 받거나 다른 앱의 창을 다루는 플러그인은 손쉬운 사용 권한이 있어야 동작해요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !trusted {
                    Button("손쉬운 사용 권한 요청하기") { SystemPermissions.requestAccessibility() }
                }
            }
        }
        .formStyle(.grouped)
        // Granting happens in System Settings; follow it while the pane is open.
        .task {
            while !Task.isCancelled {
                trusted = SystemPermissions.isAccessibilityTrusted
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
