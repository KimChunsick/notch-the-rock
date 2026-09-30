import CoreFoundation
import IOKit.ps

/// Reads the internal battery from IOKit and reports every power source change on the main
/// run loop until `stop()`.
@MainActor
final class PowerSourceMonitor {
    private let onChange: @MainActor (PowerStatus?) -> Void
    private var source: CFRunLoopSource?

    init(onChange: @escaping @MainActor (PowerStatus?) -> Void) {
        self.onChange = onChange
    }

    /// The internal battery right now, or nil when this Mac has none.
    nonisolated static func read() -> PowerStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            if let status = PowerStatus(description: description) {
                return status
            }
        }
        return nil
    }

    /// Starts listening. The monitor must stay alive until `stop()`: the IOKit callback holds it
    /// unretained.
    func start() {
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.onChange(PowerSourceMonitor.read())
            }
        }
        guard let created = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    func stop() {
        guard let source else { return }
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }
}
