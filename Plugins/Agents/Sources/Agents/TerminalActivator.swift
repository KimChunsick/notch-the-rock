import AppKit
import HookBridge

/// Brings a session's terminal to the front.
@MainActor
protocol TerminalActivating: AnyObject {
    /// False when the terminal app is not running.
    func activate(_ terminal: TerminalLocation) -> Bool
}

/// Terminal.app: selects the tab whose tty matches with AppleScript, then activates the app.
/// Ghostty and VS Code: activates the app.
@MainActor
final class SystemTerminalActivator: TerminalActivating {
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    func activate(_ terminal: TerminalLocation) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: terminal.bundleID).first,
              let url = app.bundleURL else { return false }
        if terminal.bundleID == "com.apple.Terminal", let tty = terminal.tty, let source = Self.selectTabScript(tty: tty) {
            var error: NSDictionary?
            if NSAppleScript(source: source)?.executeAndReturnError(&error) == nil {
                // Without the Automation permission the app still comes forward, on its last tab.
                log("Could not select the Terminal tab of \(tty): \(error?.description ?? "unknown error")")
            }
        }
        // Opening the running app activates it even when the notch did not make this app active.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        return true
    }

    /// The AppleScript that selects Terminal's tab on `tty`, or nil when `tty` is not a terminal device.
    static func selectTabScript(tty: String) -> String? {
        guard tty.range(of: "^/dev/tty[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        return """
        tell application id "com.apple.Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }
}
