import AppKit
import CoreGraphics

/// Delivers `NX_SYSDEFINED` events to the plugin before the system sees them. The plugin uses
/// `SystemDefinedEventTap`; tests use a fake so they never create a real event tap.
@MainActor
protocol KeyEventTap: AnyObject {
    /// Starts delivering events to `handler`, which returns true for an event it consumed. Returns
    /// false when the system refused the tap (the app lacks the Accessibility permission).
    func install(handler: @escaping @MainActor (SystemDefinedEvent) -> Bool) -> Bool
    /// Stops delivering events. Does nothing when no tap is installed.
    func remove()
}

/// A `CGEvent` tap at the HID level, placed first, that may drop events: an event the handler
/// consumes never reaches the system, so the system's own volume and brightness display stays
/// hidden. Runs on the main run loop.
final class SystemDefinedEventTap: KeyEventTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (@MainActor (SystemDefinedEvent) -> Bool)?

    func install(handler: @escaping @MainActor (SystemDefinedEvent) -> Bool) -> Bool {
        remove()
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let consumed = MainActor.assumeIsolated {
                Unmanaged<SystemDefinedEventTap>.fromOpaque(userInfo).takeUnretainedValue().receive(type, event)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventMask(NSEvent.EventType.systemDefined.rawValue),
            callback: callback,
            // The plugin keeps this object alive for as long as the app runs.
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        self.handler = handler
        return true
    }

    func remove() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
        handler = nil
    }

    /// Whether to drop the event. The system disables a tap whose callback took too long or on
    /// some user input; it is enabled again right away.
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard UInt(type.rawValue) == NSEvent.EventType.systemDefined.rawValue,
              let handler,
              let systemEvent = NSEvent(cgEvent: event)
        else { return false }
        return handler(SystemDefinedEvent(
            subtype: Int(systemEvent.subtype.rawValue),
            data1: systemEvent.data1,
            flags: event.flags
        ))
    }
}
