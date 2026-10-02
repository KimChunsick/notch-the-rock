import Foundation
import NotchKit

/// How long the notch waits for an answer to a permission request or a question before handing it
/// back to the terminal. While Claude Code waits for the AskUserQuestion hook, the terminal holds
/// its own question back, so the wait is kept short by default.
enum ApprovalWait {
    static let defaultsKey = "approvalWaitSeconds"
    static let choices = [30, 60, 120, 180, 300, 600]
    static let defaultSeconds = 120

    /// The wait on the plugin's settings page: one option per choice, stored as the seconds' text.
    static let item = PluginSettingItem.choice(
        key: defaultsKey,
        title: "노치에서 기다리는 시간",
        options: choices.map { PluginSettingOption(String($0), title: title($0)) },
        default: String(defaultSeconds)
    )

    /// The page's own picker stored the seconds as a number; rewrites such a value once as the text
    /// the declared choice keeps, so the user's wait stays.
    static func migrate(_ defaults: UserDefaults) {
        guard let stored = defaults.object(forKey: defaultsKey) as? NSNumber else { return }
        defaults.set(stored.stringValue, forKey: defaultsKey)
    }

    /// The chosen wait in seconds, or the default when nothing valid is stored. Read at every
    /// request, so a change on the settings page applies to the next one.
    @MainActor
    static func seconds(in settings: PluginSettings) -> Int {
        Int(settings.string(item)) ?? defaultSeconds
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
