import NotchKit
import SwiftUI

/// Greets the user each time the app starts and each time the screen is unlocked: the notch opens,
/// writes a greeting that suits the time and day by hand, "hello" in one cursive stroke or a Korean
/// phrase stroke by stroke, holds it long enough to read and collapses. Every unlock notification
/// starts a fresh greeting, even while one shows. The greeting can be turned off in Settings.
@MainActor
public final class HelloPlugin: NotchPlugin {
    public static let manifest = PluginManifest(
        id: "com.notchtherock.hello",
        name: "Hello",
        version: "1.0.0",
        symbol: "hand.wave",
        sdkVersion: NotchKitSDK.version
    )

    private let context: NotchContext
    /// Picks the greeting each launch or unlock writes. The app picks one at random for the current
    /// time; tests force a phrase.
    private let pickGreeting: () -> HelloGreeting
    private let unlocks: any ScreenUnlockSource
    /// Numbers each greeting, so a greeting that replaces one still on screen starts writing anew.
    private var greetingCount = 0

    public convenience init(context: NotchContext) {
        self.init(context: context) {
            var random = SystemRandomNumberGenerator()
            return HelloGreeting.random(for: Date(), calendar: .current, using: &random)
        }
    }

    init(
        context: NotchContext,
        unlocks: any ScreenUnlockSource = DistributedScreenUnlocks(),
        pickGreeting: @escaping () -> HelloGreeting
    ) {
        self.context = context
        self.unlocks = unlocks
        self.pickGreeting = pickGreeting
    }

    /// The host calls this at every app launch, including launch at login, and when the plugin is
    /// enabled again. It greets and then greets again at every unlock notification until
    /// `deactivate()`, however close together they arrive.
    public func activate() {
        unlocks.start { [weak self] in self?.greet() }
        greet()
    }

    public func deactivate() {
        unlocks.stop()
    }

    /// Reads the toggle each time, so turning it back on applies from the next unlock. The host shows
    /// one takeover at a time, so a greeting replaces one still on screen and takes its full time;
    /// a repeated system signal for one unlock only restarts the greeting, never stacks a second.
    /// The new identity makes the view start writing from the first stroke instead of keeping the
    /// replaced greeting's start.
    private func greet() {
        guard context.settings.bool(HelloPreferences.showsGreeting) else { return }
        let greeting = pickGreeting()
        greetingCount += 1
        let id = greetingCount
        context.present(Takeover(duration: greeting.timeline.duration) {
            HelloGreetingView(greeting: greeting).id(id)
        })
    }

    public var pluginDescription: PluginDescription? {
        PluginDescription(
            summary: "앱을 켤 때와 화면 잠금을 풀 때마다 노치를 펼쳐 시간과 요일에 맞는 인사를 손글씨로 써요.",
            permissions: [],
            settings: [HelloPreferences.showsGreeting]
        )
    }
}

/// The C entry symbol the app resolves after loading the bundle.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(HelloPlugin.self)
}
