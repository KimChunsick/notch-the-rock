import Foundation

/// Tells the plugin each time the user unlocks the screen. The app observes the system's unlock
/// signal; tests fire their own.
@MainActor
protocol ScreenUnlockSource: AnyObject {
    /// Calls `onUnlock` for every unlock until `stop()`. Starting again replaces the callback and
    /// keeps a single observation.
    func start(_ onUnlock: @escaping @MainActor () -> Void)
    func stop()
}

/// The distributed notification `com.apple.screenIsUnlocked`, posted when the lock screen goes away,
/// whatever locked it. NSWorkspace's `sessionDidBecomeActiveNotification` only fires when the user
/// switches back from another account, and `screensDidWakeNotification` fires when the display
/// wakes, before the password is entered and also when nothing was locked, so neither is observed.
///
/// While the center is suspended, which AppKit may do for an inactive app (an accessory app almost
/// always is), a registration without a suspension behavior only coalesces notifications, so the
/// observation asks for immediate delivery. Distributed notifications arrive on the main thread.
@MainActor
final class DistributedScreenUnlocks: NSObject, ScreenUnlockSource {
    static let screenIsUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    private var onUnlock: (@MainActor () -> Void)?

    func start(_ onUnlock: @escaping @MainActor () -> Void) {
        if self.onUnlock == nil {
            DistributedNotificationCenter.default().addObserver(
                self,
                selector: #selector(screenDidUnlock),
                name: Self.screenIsUnlocked,
                object: nil,
                suspensionBehavior: .deliverImmediately
            )
        }
        self.onUnlock = onUnlock
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self, name: Self.screenIsUnlocked, object: nil)
        onUnlock = nil
    }

    @objc nonisolated private func screenDidUnlock(_ notification: Notification) {
        MainActor.assumeIsolated { onUnlock?() }
    }
}
