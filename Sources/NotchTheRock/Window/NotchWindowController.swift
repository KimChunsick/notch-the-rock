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
/// everything around the shape stays clickable for the apps below. Keys go to
/// `NotchHostModel.handleKey(_:)` while the window is key (after a click in it, or the hotkey) and
/// the notch is expanded; another key window, such as Settings, keeps its own keys.
///
/// The global hotkey (`GlobalHotkey.app`) toggles the notch in keyboard mode: the app activates so
/// the window can become key, and when the notch collapses the app that was in front before gets
/// the focus back, unless a click in another app or another window of this app took it meanwhile.
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
    /// The app in front when the hotkey opened the notch, to give the focus back to on collapse.
    private var previousApp: NSRunningApplication?

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
        let track: (NSEvent) -> Void = { [weak self] event in
            let isClick = event.type == .leftMouseDown || event.type == .rightMouseDown
            MainActor.assumeIsolated {
                self?.handle(.pointerMoved)
                if isClick { self?.clicked() }
            }
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
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let key = HomeKey(keyCode: event.keyCode, characters: event.characters, modifierFlags: event.modifierFlags)
            let windowNumber = event.windowNumber
            let handled = MainActor.assumeIsolated {
                guard let self, let key, Self.routesKeys(
                    inNotchWindow: windowNumber == self.panel.windowNumber,
                    notchIsKey: self.panel.isKeyWindow,
                    state: self.host.state
                ) else { return false }
                return self.host.handleKey(key)
            }
            return handled ? nil : event
        }) {
            monitors.append(keys)
        }
        followExpansion()
        GlobalHotkey.app.start { [weak self] in self?.hotkeyPressed() }
    }

    private static let escapeKeyCode: UInt16 = 53

    /// Whether key events go to `NotchHostModel.handleKey(_:)`: events for the notch window while it
    /// is key and the notch is expanded. Keys for any other window go on to it untouched.
    static func routesKeys(inNotchWindow: Bool, notchIsKey: Bool, state: NotchState) -> Bool {
        inNotchWindow && notchIsKey && state == .expanded
    }

    /// Whether a key event is the notch's Esc, one of the keys `routesKeys` sends to the notch.
    static func handlesEscape(keyCode: UInt16, inNotchWindow: Bool, notchIsKey: Bool, state: NotchState) -> Bool {
        keyCode == escapeKeyCode && routesKeys(inNotchWindow: inNotchWindow, notchIsKey: notchIsKey, state: state)
    }

    /// The hotkey toggles the notch; opening it makes the window key so the keys reach it.
    private func hotkeyPressed() {
        host.toggleFromKeyboard()
        guard host.state == .expanded else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if previousApp == nil, frontmost != NSRunningApplication.current { previousApp = frontmost }
        // See `NSWindow.showInFront()`: a plain `activate()` is declined while another app is in front.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    /// A click off the shape ends a held notch. The clicked app takes the focus, so it is not given
    /// back to the app from before the hotkey.
    private func clicked() {
        guard let pointer, !pointer.takesMouseEvents(at: NSEvent.mouseLocation) else { return }
        previousApp = nil
        host.clickedOutside()
    }

    /// Gives the focus back when the notch collapses, as long as the notch window still has it: a
    /// Settings window opened from the notch keeps it.
    private func followExpansion() {
        let expanded = withObservationTracking { host.isExpanded } onChange: { [weak self] in
            Task { @MainActor in self?.followExpansion() }
        }
        guard !expanded, let previous = previousApp else { return }
        previousApp = nil
        guard panel.isKeyWindow, !previous.isTerminated else { return }
        NSApp.yieldActivation(to: previous)
        previous.activate()
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
            if hovering { self?.host.setHovering(true) } else { self?.host.pointerLeft() }
        }
    }
}
