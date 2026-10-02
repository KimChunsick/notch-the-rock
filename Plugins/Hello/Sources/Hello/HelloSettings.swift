import NotchKit

/// The plugin's one setting, declared on its settings page and kept in its NotchKit defaults suite
/// under the key the earlier toggle used, so the user's choice stays. The greeting reads it here.
enum HelloPreferences {
    /// Whether the plugin writes the greeting in the notch at launch and at every unlock.
    static let showsGreeting = PluginSettingItem.toggle(
        key: "showsGreeting",
        title: "앱을 켜거나 화면 잠금을 풀 때 인사 애니메이션 보여주기",
        detail: "끄면 노치가 접힌 채로 있어요.",
        default: true
    )
}
