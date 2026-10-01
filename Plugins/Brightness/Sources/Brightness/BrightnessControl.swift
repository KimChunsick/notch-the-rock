import CoreGraphics
import Darwin

/// The brightness of the built-in display. The plugin uses `DisplayServicesBrightness`; tests use a
/// fake so they never touch the user's display.
@MainActor
protocol BrightnessControl: AnyObject {
    /// From 0 to 1, or nil when there is no built-in display or its brightness cannot be changed.
    func read() -> Double?
    /// False when the display refused the value or is gone.
    func set(_ value: Double) -> Bool
}

/// The built-in display through the private DisplayServices framework. The framework is opened at
/// run time with `dlopen`, so the plugin has no link-time dependency on it; when the framework or one
/// of its functions is missing, `read()` returns nil and the brightness keys stay with the system.
final class DisplayServicesBrightness: BrightnessControl {
    static let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private struct Functions {
        let canChange: CanChangeBrightness
        let get: GetBrightness
        let set: SetBrightness
    }

    private let functions: Functions?

    init() {
        functions = Self.resolve()
    }

    /// Whether the framework and its three brightness functions were found.
    var isResolved: Bool { functions != nil }

    func read() -> Double? {
        guard let functions, let display = Self.builtInDisplay(), functions.canChange(display) else { return nil }
        var value: Float = 0
        guard functions.get(display, &value) == 0 else { return nil }
        return Double(min(max(value, 0), 1))
    }

    func set(_ value: Double) -> Bool {
        guard let functions, let display = Self.builtInDisplay() else { return false }
        return functions.set(display, Float(min(max(value, 0), 1))) == 0
    }

    private static func resolve() -> Functions? {
        guard let handle = dlopen(frameworkPath, RTLD_LAZY),
              let canChange = dlsym(handle, "DisplayServicesCanChangeBrightness"),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness")
        else { return nil }
        return Functions(
            canChange: unsafeBitCast(canChange, to: CanChangeBrightness.self),
            get: unsafeBitCast(get, to: GetBrightness.self),
            set: unsafeBitCast(set, to: SetBrightness.self)
        )
    }

    /// The online built-in display; none while the lid is closed.
    private static func builtInDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }
}
