import Foundation
import NotchKit
import Testing
@testable import Hello

/// An unlock source the test fires by hand. Stopping it drops the plugin's callback.
@MainActor
final class FakeUnlocks: ScreenUnlockSource {
    private var onUnlock: (@MainActor () -> Void)?
    var isObserving: Bool { onUnlock != nil }

    func start(_ onUnlock: @escaping @MainActor () -> Void) { self.onUnlock = onUnlock }
    func stop() { onUnlock = nil }
    func fire() { onUnlock?() }
}

/// A clock the test moves by hand.
@MainActor
final class ManualClock {
    private(set) var now = ContinuousClock.now
    func advance(by duration: Duration) { now = now.advanced(by: duration) }
}

@MainActor
@Suite struct UnlockGreetingTests {
    let unlocks = FakeUnlocks()
    let clock = ManualClock()

    /// A plugin wired to the fake source and clock; `picked` counts the greetings it picks.
    func plugin(_ context: NotchContext, picked: @escaping () -> Void = {}) -> HelloPlugin {
        let clock = clock
        return HelloPlugin(context: context, unlocks: unlocks, now: { clock.now }) {
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
                clock.advance(by: .seconds(60))
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
            clock.advance(by: .seconds(1))
            unlocks.fire()
            #expect(host.takeovers.count == 2)
            #expect(picks == 2)
            #expect(host.takeovers.allSatisfy { $0.duration == HelloTimeline.hello.duration })
        }
    }

    /// A second unlock while the first unlock's greeting still shows greets again.
    @Test func R30__distinct_unlocks_seconds_apart_greet_each_time() throws {
        try withContext { context, host in
            let plugin = plugin(context)
            plugin.activate()
            clock.advance(by: .seconds(60))
            unlocks.fire()
            #expect(host.takeovers.count == 2)
            clock.advance(by: .seconds(3))
            unlocks.fire()
            #expect(host.takeovers.count == 3)
        }
    }

    /// Signals less than a second after the unlock that counted are the same unlock; the first
    /// signal a second or more after it greets.
    @Test func R30__a_duplicate_unlock_signal_greets_once() throws {
        try withContext { context, host in
            let plugin = plugin(context)
            plugin.activate()
            clock.advance(by: .seconds(60))
            unlocks.fire()
            clock.advance(by: .milliseconds(300))
            unlocks.fire()
            clock.advance(by: .milliseconds(600))
            unlocks.fire()
            #expect(host.takeovers.count == 2)

            clock.advance(by: .milliseconds(100))
            unlocks.fire()
            #expect(host.takeovers.count == 3)
        }
    }

    @Test func R30__unlocks_do_not_greet_while_greetings_are_off() throws {
        try withContext { context, host in
            let preferences = HelloPreferences(defaults: context.storage.defaults)
            preferences.showsGreeting = false
            let plugin = plugin(context)
            plugin.activate()
            for _ in 1...2 {
                clock.advance(by: .seconds(60))
                unlocks.fire()
            }
            #expect(host.takeovers.isEmpty)

            // Turned back on in Settings, the next unlock greets without restarting the app.
            preferences.showsGreeting = true
            clock.advance(by: .seconds(60))
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
            clock.advance(by: .seconds(60))
            unlocks.fire()
            #expect(host.takeovers.count == 1)

            // Enabled again, the plugin greets and follows unlocks once more.
            plugin.activate()
            #expect(host.takeovers.count == 2)
            clock.advance(by: .seconds(60))
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
