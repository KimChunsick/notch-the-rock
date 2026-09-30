import ApplicationServices
import ServiceManagement

/// The app's Accessibility trust and its login item. Every place that reads or changes them (the
/// Settings panes, `--print-permissions`, onboarding) goes through here.
@MainActor
enum SystemPermissions {
    /// `SMAppService.Status` with the spelling `--print-permissions` prints (`login-item=enabled`).
    enum LoginItemStatus: String, Sendable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound

        init(_ status: SMAppService.Status) {
            switch status {
            case .enabled: self = .enabled
            case .requiresApproval: self = .requiresApproval
            case .notRegistered: self = .notRegistered
            case .notFound: self = .notFound
            @unknown default: self = .notFound
            }
        }

        /// Registered, even when the user still has to approve it in System Settings.
        var isRegistered: Bool { self == .enabled || self == .requiresApproval }

        var label: String {
            switch self {
            case .enabled: "켜져 있어요"
            case .requiresApproval: "시스템 설정의 로그인 항목에서 허용해야 해요"
            case .notRegistered: "등록되지 않았어요"
            case .notFound: "시스템에서 로그인 항목을 찾지 못했어요"
            }
        }
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility when not trusted yet.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static var loginItemStatus: LoginItemStatus { LoginItemStatus(SMAppService.mainApp.status) }

    /// Registers or unregisters the app as a login item. The error is the system's, unchanged.
    static func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// What `--print-permissions` prints, one `key=value` per line.
    static var report: String {
        """
        accessibility=\(isAccessibilityTrusted ? "trusted" : "untrusted")
        login-item=\(loginItemStatus.rawValue)
        """
    }
}
