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
/// hover (`NotchPointer`): the window takes clicks only while the pointer is on the drawn shape, so
/// everything around the shape stays clickable for the apps below. Esc goes to
/// `NotchHostModel.escape()` while the window is key (after a click in it); another key window, such
/// as Settings, keeps its own Esc.
@MainActor
final class NotchWindowController {
    /// Pointer must rest on the notch this long before it opens, so passing by does not open it.
    private static let openIntent: Duration = .milliseconds(120)
    private static let closeDelay: Duration = .milliseconds(200)

    private let host: NotchHostModel
    private let openSettings: @MainActor () -> Void
    private let panel = NotchPanel()
    private let hostingView: NotchHostingView
    /// Set once the window is placed over a notch.
    private var pointer: NotchPointer?
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
            MainActor.assumeIsolated { self?.handle(.pointerMoved) }
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
        if let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let keyCode = event.keyCode
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                guard let self, Self.handlesEscape(
                    keyCode: keyCode,
                    inNotchWindow: windowNumber == self.panel.windowNumber,
                    notchIsKey: self.panel.isKeyWindow,
                    state: self.host.state
                ) else { return false }
                self.host.escape()
                return true
            }
            return handled ? nil : event
        }) {
            monitors.append(escape)
        }
    }

    private static let escapeKeyCode: UInt16 = 53

    /// Whether a key event is the notch's Esc: Esc for the notch window while it is key and the
    /// notch is expanded. Esc for any other window goes on to that window untouched.
    static func handlesEscape(keyCode: UInt16, inNotchWindow: Bool, notchIsKey: Bool, state: NotchState) -> Bool {
        keyCode == escapeKeyCode && inNotchWindow && notchIsKey && state == .expanded
    }

    private func placeOnScreen() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
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
        let notchRect = geometry.notchRect
        if pointer == nil {
            pointer = NotchPointer(
                notchRect: notchRect,
                metrics: NotchLayout.metrics(for: host.state, notch: notchRect.size, hasActivity: host.liveActivity != nil)
            )
        }
        pointer?.notchRect = notchRect
        // The shape changes with the host state and the measured content even when the pointer does
        // not move; the root view reports where it is heading, every frame drawn on the way, and
        // tile drags.
        hostingView.rootView = NotchRootView(
            host: host,
            notchSize: notchRect.size,
            openSettings: openSettings,
            metricsChanged: { [weak self] metrics in self?.handle(.shapeChanged(metrics)) },
            shapeDrawn: { [weak self] metrics in self?.handle(.shapeDrawn(metrics)) },
            dragChanged: { [weak self] dragging in self?.handle(dragging ? .dragBegan : .dragEnded) }
        )
    }

    /// Feeds `event` to the pointer tracking, lets the window take mouse events where it says and
    /// schedules the hover change it asks for.
    private func handle(_ event: NotchPointer.Event) {
        guard var pointer else { return }
        let location = NSEvent.mouseLocation
        let hover = pointer.handle(event, at: location)
        self.pointer = pointer
        let ignores = !pointer.takesMouseEvents(at: location)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
        guard let hover else { return }
        hoverTask?.cancel()
        hoverTask = nil
        let hovering: Bool
        let delay: Duration
        switch hover {
        case .enter: (hovering, delay) = (true, Self.openIntent)
        case .leave: (hovering, delay) = (false, Self.closeDelay)
        case .hold: return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.host.setHovering(hovering)
        }
    }
}
