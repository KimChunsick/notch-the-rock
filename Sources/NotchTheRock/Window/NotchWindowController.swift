import AppKit
import SwiftUI

/// Borderless, non-activating panel above the menu bar, on every Space and beside full-screen
/// apps, left out of Mission Control and window cycling.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    /// Key so an attention text field can take typing; the app itself stays inactive.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit would push the window below the menu bar; the notch belongs on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Buttons in the notch react to the first click even though the app is never active.
private final class NotchHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Places the notch window over the notch of the preferred screen and turns pointer movement into
/// hover: the window takes clicks only while the pointer is on the drawn shape, so everything
/// around the shape stays clickable for the apps below.
@MainActor
final class NotchWindowController {
    /// Pointer must rest on the notch this long before it opens, so passing by does not open it.
    private static let openIntent: Duration = .milliseconds(120)
    private static let closeDelay: Duration = .milliseconds(200)

    private let host: NotchHostModel
    private let openSettings: @MainActor () -> Void
    private let panel = NotchPanel()
    private let hostingView: NotchHostingView
    private var geometry: NotchGeometry?
    private var pointerInside = false
    private var hoverTask: Task<Void, Never>?
    private var monitors: [Any] = []

    /// - Parameter openSettings: called by the gear button and the 설정… menu item.
    init(host: NotchHostModel, openSettings: @escaping @MainActor () -> Void) {
        self.host = host
        self.openSettings = openSettings
        hostingView = NotchHostingView(rootView: NotchRootView(host: host, notchSize: .zero, openSettings: openSettings))
        hostingView.safeAreaRegions = []
        panel.contentView = hostingView
    }

    func show() {
        placeOnScreen()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.placeOnScreen() }
        }
        let track: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer() }
        }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDown, .leftMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: track) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { event in
            track(event)
            return event
        }) {
            monitors.append(local)
        }
        observeHost()
    }

    private func placeOnScreen() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        self.geometry = geometry
        let canvas = NotchLayout.canvasSize
        panel.setFrame(
            CGRect(
                x: geometry.notchRect.midX - canvas.width / 2,
                y: geometry.screenFrame.maxY - canvas.height,
                width: canvas.width,
                height: canvas.height
            ),
            display: true
        )
        hostingView.rootView = NotchRootView(host: host, notchSize: geometry.notchRect.size, openSettings: openSettings)
        trackPointer()
    }

    /// The shape changes with the host state even when the pointer does not move.
    private func observeHost() {
        withObservationTracking {
            _ = host.state
            _ = host.liveActivity != nil
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.trackPointer()
                self?.observeHost()
            }
        }
    }

    private func trackPointer() {
        guard let geometry else { return }
        let metrics = NotchLayout.metrics(for: host.state, notch: geometry.notchRect.size, hasActivity: host.liveActivity != nil)
        let inside = NotchLayout.contains(NSEvent.mouseLocation, metrics: metrics, notchRect: geometry.notchRect)
        panel.ignoresMouseEvents = !inside
        guard inside != pointerInside else { return }
        pointerInside = inside
        hoverTask?.cancel()
        let delay = inside ? Self.openIntent : Self.closeDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.host.setHovering(inside)
        }
    }
}
