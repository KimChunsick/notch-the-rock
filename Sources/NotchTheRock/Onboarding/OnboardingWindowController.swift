import AppKit
import OSLog
import SwiftUI

/// The first-launch onboarding window. It opens after the notch's greeting so it never covers it,
/// and closing it counts as finishing; the app quitting does not. It floats above other apps'
/// windows until then: once the user clicks another app, an ordinary window of this accessory app
/// ends up behind that app's windows, with no Dock icon or app switcher entry to bring it back.
/// While the user is in System Settings for a permission it steps down to the normal level, so it
/// does not cover the switch they have to flip, and a grant brings it back to the front.
///
/// Debug builds only: NOTCH_DEBUG_ONBOARDING_AUTOPLAY=<seconds> in the environment does what Enter
/// does every that many seconds until the last step, which stays open, so every step can be
/// captured without a keyboard. It never turns a permission or the login item on.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 540, height: 460)
    static let cornerRadius: CGFloat = 16

    let model: OnboardingModel
    private var window: NSWindow?
    private var appIsTerminating = false
    private let logger = Logger(subsystem: "com.notchtherock.NotchTheRock", category: "onboarding")

    init(model: OnboardingModel) {
        self.model = model
        super.init()
        model.onFinish = { [weak self] in self?.window?.close() }
        model.onOpenSystemSettings = { [weak self] in self?.stepAside() }
        model.onPermissionGranted = { [weak self] in self?.bringForward() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    /// Opens the window once `isGreeting` turns false, or after `limit` at the latest.
    func show(after isGreeting: @escaping @MainActor () -> Bool, limit: Duration = .milliseconds(3500)) {
        Task {
            let start = ContinuousClock.now
            while isGreeting(), ContinuousClock.now - start < limit {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let reason = isGreeting() ? "the wait limit, greeting still showing" : "the greeting ended"
            logger.notice("onboarding window opened after \(reason, privacy: .public) (\(ContinuousClock.now - start, privacy: .public) after plugins loaded)")
            present()
        }
    }

    private func present() {
        let window = makeWindow()
        model.start()
        window.showInFront()
        #if DEBUG
        autoplayForCaptures()
        #endif
    }

    /// Brings the open window back to the front and floating again, for a reopen of the running app
    /// and for a grant noticed while the user was in System Settings. During the greeting there is
    /// no window yet; it opens by itself when the greeting ends.
    func bringForward() {
        guard let window else {
            logger.notice("reopened during the greeting; the onboarding window opens when it ends")
            return
        }
        window.level = .floating
        window.showInFront()
    }

    /// 권한 열기 or 설정 열기 sent the user to System Settings, which the floating window would cover.
    private func stepAside() {
        window?.level = .normal
        logger.notice("onboarding window stepped aside for System Settings")
    }

    /// The user came back to the window by clicking it: it floats again, so the next app the user
    /// clicks does not bury it.
    func windowDidBecomeKey(_ notification: Notification) {
        window?.level = .floating
    }

    /// Makes the window this controller shows. It has no title bar: a rounded, dark translucent
    /// background, whatever the system appearance, that can be dragged anywhere. It gets its size
    /// before it is centred.
    func makeWindow() -> NSWindow {
        let frame = NSRect(origin: .zero, size: Self.size)
        let window = OnboardingWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Not drawn; names the window for accessibility and the window list.
        window.title = "NotchTheRock 시작하기"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true

        let background = NSVisualEffectView(frame: frame)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)
        let content = NSHostingView(rootView: OnboardingView(model: model))
        content.sizingOptions = []
        content.frame = background.bounds
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        window.contentView = background

        window.isReleasedWhenClosed = false
        window.level = .floating
        window.hidesOnDeactivate = false
        window.delegate = self
        window.center()
        self.window = window
        return window
    }

    /// A stretchable rounded rectangle: the window's shape, and with it the shadow's.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the window first: finish() calls onFinish, which would close it a second time.
        window?.delegate = nil
        window = nil
        guard !appIsTerminating else {
            logger.notice("app quit with the onboarding open; it shows again on the next launch")
            return
        }
        model.finish()
        logger.notice("onboarding completed")
    }

    /// Quitting or logging out closes the window as well; that is not the user finishing it.
    @objc private func applicationWillTerminate(_ notification: Notification) {
        appIsTerminating = true
    }

    #if DEBUG
    private func autoplayForCaptures() {
        guard let value = ProcessInfo.processInfo.environment["NOTCH_DEBUG_ONBOARDING_AUTOPLAY"],
              let seconds = Double(value), seconds > 0 else { return }
        logger.notice("NOTCH_DEBUG_ONBOARDING_AUTOPLAY: pressing Enter every \(seconds, privacy: .public) s")
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(seconds))
                guard let self, !self.model.isFinished, !self.model.isLastStep else { return }
                self.model.advance()
            }
        }
    }
    #endif
}

/// Borderless, so there is no title bar, yet it takes the keyboard like a titled window: Enter and
/// Esc drive the steps.
final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
