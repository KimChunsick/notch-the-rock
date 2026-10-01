import NotchKit
import SwiftUI

/// Greets the user each time the app starts and each time the screen is unlocked: the notch opens,
/// writes a greeting that suits the time and day by hand, "hello" in one cursive stroke or a Korean
/// phrase stroke by stroke, holds it long enough to read and collapses. An unlock while a greeting
/// shows starts a fresh one. The greeting can be turned off in Settings.
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
    /// When the last unlock that counted was signalled. Only unlocks set it, so the launch greeting
    /// never holds back an unlock.
    private var lastUnlock: ContinuousClock.Instant?
    /// Numbers each greeting, so a greeting that replaces one still on screen starts writing anew.
    private var greetingCount = 0

    /// Unlock signals less than this long after the last unlock that counted are the same unlock:
    /// the lock screen has to appear and the user has to authenticate before the next unlock, which
    /// takes longer than a second.
    static let unlockMergeWindow: Duration = .seconds(1)

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

    /// Every unlock greets, even while a greeting still shows; only a repeated signal of the same
    /// unlock is merged.
    private func screenDidUnlock() {
        let signalled = now()
        if let lastUnlock, signalled - lastUnlock < Self.unlockMergeWindow { return }
        lastUnlock = signalled
        greet()
    }

    /// Reads the toggle each time, so turning it back on applies from the next unlock. The host shows
    /// one takeover at a time, so a greeting replaces one still on screen and takes its full time.
    /// The new identity makes the view start writing from the first stroke instead of keeping the
    /// replaced greeting's start.
    private func greet() {
        guard preferences.showsGreeting else { return }
        let greeting = pickGreeting()
        greetingCount += 1
        let id = greetingCount
        context.present(Takeover(duration: greeting.timeline.duration) {
            HelloGreetingView(greeting: greeting).id(id)
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
