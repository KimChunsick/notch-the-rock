import Foundation

/// How long the notch waits for an answer to a permission request or a question before handing it
/// back to the terminal. While Claude Code waits for the AskUserQuestion hook, the terminal holds
/// its own question back, so the wait is kept short by default.
enum ApprovalWait {
    static let defaultsKey = "approvalWaitSeconds"
    static let choices = [30, 60, 120, 180, 300, 600]
    static let defaultSeconds = 120

    /// The chosen wait in seconds, or the default when nothing valid is stored.
    static func seconds(in defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: defaultsKey)
        return choices.contains(stored) ? stored : defaultSeconds
    }

    /// The hook timeout installed for requests: longer than any wait, so Claude Code never ends a
    /// hook the notch still waits on.
    static var hookTimeout: Int {
        (choices.max() ?? defaultSeconds) + 30
    }

    static func title(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds)초" : "\(seconds / 60)분"
    }
}
