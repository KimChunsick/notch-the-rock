import NotchKit
import SwiftUI

/// Greets the user each time the app starts: the notch opens, writes a greeting that suits the time
/// and day by hand, "hello" in one cursive stroke or a Korean phrase stroke by stroke, holds it long
/// enough to read and collapses. The greeting can be turned off in Settings.
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
    /// Picks the greeting each activation writes. The app picks one at random for the current time;
    /// tests force a phrase.
    private let pickGreeting: () -> HelloGreeting

    public convenience init(context: NotchContext) {
        self.init(context: context) {
            var random = SystemRandomNumberGenerator()
            return HelloGreeting.random(for: Date(), calendar: .current, using: &random)
        }
    }

    init(context: NotchContext, pickGreeting: @escaping () -> HelloGreeting) {
        self.context = context
        self.pickGreeting = pickGreeting
    }

    private var preferences: HelloPreferences {
        HelloPreferences(defaults: context.storage.defaults)
    }

    /// The host calls this at every app launch, including launch at login.
    public func activate() {
        guard preferences.showsGreeting else { return }
        let greeting = pickGreeting()
        context.present(Takeover(duration: greeting.timeline.duration) {
            HelloGreetingView(greeting: greeting)
        })
    }

    public func deactivate() {}

    public var settingsView: AnyView? {
        AnyView(HelloSettingsView(defaults: context.storage.defaults))
    }
}

/// The C entry symbol the app resolves after loading the bundle.
@_cdecl("notchkit_plugin_entry")
public func notchkitPluginEntry() -> UnsafeMutableRawPointer {
    NotchPluginEntry.export(HelloPlugin.self)
}
