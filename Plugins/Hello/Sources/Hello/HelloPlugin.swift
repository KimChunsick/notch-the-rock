import NotchKit
import SwiftUI

/// Greets the user each time the app starts and each time the screen is unlocked: the notch opens,
/// writes a greeting that suits the time and day by hand, "hello" in one cursive stroke or a Korean
/// phrase stroke by stroke, holds it long enough to read and collapses. The greeting can be turned
/// off in Settings.
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
    private let now: @MainActor () -> ContinuousClock.Instant
    /// Unlock signals before this instant are ignored: the last greeting is still on screen, or the
    /// same unlock is still signalling.
    private var quietUntil: ContinuousClock.Instant?

    /// The shortest time after a greeting starts during which unlock signals are ignored.
    static let unlockQuietPeriod: Duration = .seconds(5)

    public convenience init(context: NotchContext) {
        self.init(context: context) {
            var random = SystemRandomNumberGenerator()
            return HelloGreeting.random(for: Date(), calendar: .current, using: &random)
        }
    }

    init(
        context: NotchContext,
        unlocks: any ScreenUnlockSource = DistributedScreenUnlocks(),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        pickGreeting: @escaping () -> HelloGreeting
    ) {
        self.context = context
        self.unlocks = unlocks
        self.now = now
        self.pickGreeting = pickGreeting
    }

    private var preferences: HelloPreferences {
        HelloPreferences(defaults: context.storage.defaults)
    }

    /// The host calls this at every app launch, including launch at login, and when the plugin is
    /// enabled again. It greets and then greets again at every unlock until `deactivate()`.
    public func activate() {
        unlocks.start { [weak self] in self?.screenDidUnlock() }
        greet()
    }

    public func deactivate() {
        unlocks.stop()
    }

    private func screenDidUnlock() {
        if let quietUntil, now() < quietUntil { return }
        greet()
    }

    /// Reads the toggle each time, so turning it back on applies from the next unlock.
    private func greet() {
        guard preferences.showsGreeting else { return }
        let greeting = pickGreeting()
        let duration = greeting.timeline.duration
        quietUntil = now() + max(duration, Self.unlockQuietPeriod)
        context.present(Takeover(duration: duration) {
            HelloGreetingView(greeting: greeting)
        })
    }

    public var settingsView: AnyView? {
        AnyView(HelloSettingsView(defaults: context.storage.defaults))
    }
}

/// The C entry symbol the app resolves after loading the bundle.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(HelloPlugin.self)
}
