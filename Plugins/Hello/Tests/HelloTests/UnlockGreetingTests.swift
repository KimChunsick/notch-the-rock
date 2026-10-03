import Foundation
import NotchKit
import Testing
@testable import Hello

/// An unlock source the test fires by hand. Stopping it drops the plugin's callback.
@MainActor
final class FakeUnlocks: ScreenUnlockSource {
    private var onUnlock: (@MainActor () -> Void)?
    var isObserving: Bool { onUnlock != nil }
    private(set) var starts = 0

    func start(_ onUnlock: @escaping @MainActor () -> Void) {
        starts += 1
        self.onUnlock = onUnlock
    }
    func stop() { onUnlock = nil }
    func fire() { onUnlock?() }
}

@MainActor
@Suite struct UnlockGreetingTests {
    let unlocks = FakeUnlocks()

    /// A plugin wired to the fake source; `picked` counts the greetings it picks.
    func plugin(_ context: NotchContext, picked: @escaping () -> Void = {}) -> HelloPlugin {
        HelloPlugin(context: context, unlocks: unlocks) {
            picked()
            return HelloGreeting(phrase: HelloPhrases.hello)
        }
    }

    @Test func R30__each_unlock_presents_one_fresh_greeting() throws {
        try withContext { context, host in
            var picks = 0
            let plugin = plugin(context) { picks += 1 }
            plugin.activate()
            #expect(host.takeovers.count == 1)

            for unlock in 1...3 {
                unlocks.fire()
                #expect(host.takeovers.count == 1 + unlock)
                #expect(picks == 1 + unlock)
            }
            #expect(host.takeovers.allSatisfy { $0.pluginID == HelloPlugin.manifest.id })
            #expect(host.takeovers.allSatisfy { $0.duration == HelloTimeline.hello.duration })
        }
    }

    /// The launch greeting does not hold back an unlock: the unlock replaces it with a fresh one.
    @Test func R30__an_unlock_right_after_launch_greets_again() throws {
        try withContext { context, host in
            var picks = 0
            let plugin = plugin(context) { picks += 1 }
            plugin.activate()
            unlocks.fire()
            #expect(host.takeovers.count == 2)
            #expect(picks == 2)
            #expect(host.takeovers.allSatisfy { $0.duration == HelloTimeline.hello.duration })
        }
    }

    /// A second unlock while the first unlock's greeting still shows greets again.
    @Test func R30__an_unlock_while_a_greeting_shows_greets_again() throws {
        try withContext { context, host in
            let plugin = plugin(context)
            plugin.activate()
            unlocks.fire()
            #expect(host.takeovers.count == 2)
            unlocks.fire()
            #expect(host.takeovers.count == 3)
        }
    }

    /// Signals at t, t+0.3 s and t+0.9 s are three notifications, so they greet three times. The
    /// plugin reads no clock, so firing them back to back covers every spacing, these included.
    @Test func R30__every_unlock_signal_greets_however_close() throws {
        try withContext { context, host in
            var picks = 0
            let plugin = plugin(context) { picks += 1 }
            plugin.activate()
            unlocks.fire()
            #expect(host.takeovers.count == 2)
            unlocks.fire()
            #expect(host.takeovers.count == 3)
            unlocks.fire()
            #expect(host.takeovers.count == 4)
            #expect(picks == 4)
        }
    }

    @Test func R30__unlocks_do_not_greet_while_greetings_are_off() throws {
        try withContext { context, host in
            context.settings.set(false, for: HelloPreferences.showsGreeting)
            let plugin = plugin(context)
            plugin.activate()
            for _ in 1...2 {
                unlocks.fire()
            }
            #expect(host.takeovers.isEmpty)

            // Turned back on in Settings, the next unlock greets without restarting the app.
            context.settings.set(true, for: HelloPreferences.showsGreeting)
            unlocks.fire()
            #expect(host.takeovers.count == 1)
        }
    }

    @Test func R30__deactivate_stops_unlock_greetings() throws {
        try withContext { context, host in
            let plugin = plugin(context)
            plugin.activate()
            #expect(unlocks.isObserving)
            plugin.deactivate()
            #expect(!unlocks.isObserving)
            unlocks.fire()
            #expect(host.takeovers.count == 1)

            // Enabled again, the plugin greets and follows unlocks once more.
            plugin.activate()
            #expect(host.takeovers.count == 2)
            unlocks.fire()
            #expect(host.takeovers.count == 3)
        }
    }

    /// Activating twice greets once and starts one observation; after `deactivate()`, activating
    /// again greets and observes as the first activation did.
    @Test func R64__hello_activates_once_and_starts_afresh_after_deactivate() throws {
        try withContext { context, host in
            let plugin = plugin(context)
            plugin.activate()
            plugin.activate()
            #expect(host.takeovers.count == 1)
            #expect(unlocks.starts == 1)

            plugin.deactivate()
            #expect(!unlocks.isObserving)

            plugin.activate()
            #expect(host.takeovers.count == 2)
            #expect(unlocks.starts == 2)
            unlocks.fire()
            #expect(host.takeovers.count == 3)
        }
    }

    /// The app builds the plugin with `init(context:)` and calls `activate()` at every launch,
    /// including the login item's launch after a reboot.
    @Test func R30__launch_still_greets() throws {
        try withContext { context, host in
            let plugin = HelloPlugin(context: context)
            plugin.activate()
            #expect(host.takeovers.count == 1)
            #expect(host.takeovers.first?.pluginID == HelloPlugin.manifest.id)
            plugin.deactivate()
        }
    }
}
