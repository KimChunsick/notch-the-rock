import SwiftUI

/// The plugin's settings, kept in its own NotchKit defaults suite. The key and the default live
/// only here; the greeting and the settings toggle both read them.
struct HelloPreferences {
    static let showsGreetingKey = "showsGreeting"
    static let showsGreetingByDefault = true

    let defaults: UserDefaults

    /// Whether the plugin writes the greeting in the notch at launch and at every unlock.
    var showsGreeting: Bool {
        get { defaults.object(forKey: Self.showsGreetingKey) as? Bool ?? Self.showsGreetingByDefault }
        nonmutating set { defaults.set(newValue, forKey: Self.showsGreetingKey) }
    }
}

/// The plugin's page in the Settings window.
struct HelloSettingsView: View {
    @AppStorage private var showsGreeting: Bool

    init(defaults: UserDefaults) {
        _showsGreeting = AppStorage(
            wrappedValue: HelloPreferences.showsGreetingByDefault,
            HelloPreferences.showsGreetingKey,
            store: defaults
        )
    }

    var body: some View {
        Form {
            Toggle("앱을 켜거나 화면 잠금을 풀 때 인사 애니메이션 보여주기", isOn: $showsGreeting)
            Text("앱을 켜거나 로그인할 때 자동으로 실행되면, 그리고 화면 잠금을 풀 때마다 노치가 펼쳐지고 시간과 요일에 맞는 인사를 손글씨로 한 획씩 써요. 끄면 노치가 접힌 채로 있어요.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
