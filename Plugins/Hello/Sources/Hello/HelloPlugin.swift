import NotchKit
import SwiftUI

/// Greets the user each time the app starts: the notch opens, writes "hello" stroke by stroke and
/// collapses about three seconds later. The greeting can be turned off in Settings.
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

    public init(context: NotchContext) {
        self.context = context
    }

    private var preferences: HelloPreferences {
        HelloPreferences(defaults: context.storage.defaults)
    }

    /// The host calls this at every app launch, including launch at login.
    public func activate() {
        guard preferences.showsGreeting else { return }
        context.present(Takeover(duration: HelloTimeline.duration) {
            HelloGreetingView()
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
