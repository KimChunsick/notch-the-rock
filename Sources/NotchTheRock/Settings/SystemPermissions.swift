import AppKit
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

        /// `.notFound` is what the system reports before the app has ever registered, so it reads as
        /// "off" like `.notRegistered`; a failed registration shows `launchAtLoginFailure` instead.
        var label: String {
            switch self {
            case .enabled: "켜져 있어요"
            case .requiresApproval: "시스템 설정의 로그인 항목에서 허용해야 해요"
            case .notRegistered, .notFound: "꺼져 있어요"
            }
        }
    }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility when not trusted yet.
    static func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Opens System Settings at Privacy & Security > Accessibility.
    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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

    /// What the Settings pane and onboarding say when `setLaunchAtLogin(_:)` throws.
    static func launchAtLoginFailure(enabling enabled: Bool, _ error: any Error) -> String {
        let action = enabled ? "등록하지" : "해제하지"
        return "로그인 항목을 \(action) 못했어요: \(error.localizedDescription)"
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
