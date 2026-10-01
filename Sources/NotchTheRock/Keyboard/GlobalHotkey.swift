import Carbon.HIToolbox
import Foundation
import Observation

/// Registers the one global hotkey with the system. Tests use a fake: no test process registers a
/// real hotkey.
@MainActor
protocol HotkeyRegistrar: AnyObject {
    /// Registers `shortcut` in place of nothing (callers unregister first) and calls `pressed` on
    /// every press from any app. False when the system or another app already has the shortcut.
    func register(_ shortcut: KeyShortcut, pressed: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// The global hotkey that opens the notch: the stored shortcut, its registration and the last
/// refusal, the single owner of all three. Settings changes it here; the notch window starts it.
///
/// A change registers the new shortcut before anything is stored: when the system refuses it, the
/// current shortcut is registered again, stays stored and keeps working.
@MainActor
@Observable
final class GlobalHotkey {
    static let defaultsKey = "GlobalHotkey"

    /// The app's hotkey, stored in the app's defaults. `main.swift` builds the notch window and
    /// Settings separately, so both reach it here. Creating it registers nothing; `start(pressed:)`
    /// does.
    static let app = GlobalHotkey(defaults: .standard, registrar: CarbonHotkeyRegistrar())

    private(set) var shortcut: KeyShortcut
    /// The shortcut the system refused at the last start or change, until a change succeeds.
    private(set) var refused: KeyShortcut?
    private(set) var isRegistered = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let registrar: HotkeyRegistrar
    @ObservationIgnored private var pressed: (@MainActor () -> Void)?

    init(defaults: UserDefaults, registrar: HotkeyRegistrar) {
        self.defaults = defaults
        self.registrar = registrar
        shortcut = defaults.data(forKey: Self.defaultsKey).flatMap(KeyShortcut.init(encoded:)) ?? .default
    }

    /// Registers the stored shortcut; every press calls `pressed`.
    func start(pressed: @escaping @MainActor () -> Void) {
        self.pressed = pressed
        registrar.unregister()
        isRegistered = registrar.register(shortcut, pressed: pressed)
        refused = isRegistered ? nil : shortcut
    }

    /// Replaces the shortcut. Returns false, keeping the current one, when the system refuses `new`.
    @discardableResult
    func change(to new: KeyShortcut) -> Bool {
        if let pressed {
            registrar.unregister()
            guard registrar.register(new, pressed: pressed) else {
                refused = new
                isRegistered = registrar.register(shortcut, pressed: pressed)
                return false
            }
            isRegistered = true
        }
        shortcut = new
        refused = nil
        defaults.set(new.encoded, forKey: Self.defaultsKey)
        return true
    }

    /// Back to ⌃⌥N.
    func reset() {
        change(to: .default)
    }

    /// Stops the hotkey while Settings records a new one, so pressing the current shortcut records it
    /// instead of opening the notch.
    func suspend() {
        registrar.unregister()
        isRegistered = false
    }

    /// Registers the current shortcut again after `suspend()`, unless a change already did.
    func resume() {
        guard let pressed, !isRegistered else { return }
        isRegistered = registrar.register(shortcut, pressed: pressed)
    }
}

/// `RegisterEventHotKey`: the system consumes the key and tells the app, from any app and without
/// Accessibility. A shortcut macOS itself has enabled (Keyboard Shortcuts in System Settings, such
/// as ⌃⌥Space for the input sources) would never reach the app, so it counts as refused too.
@MainActor
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    private static let signature: OSType = 0x4E_54_52_4B // 'NTRK'

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed: (@MainActor () -> Void)?

    func register(_ shortcut: KeyShortcut, pressed: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        guard !Self.isSystemShortcut(shortcut), installHandler() else { return false }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            shortcut.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &reference
        )
        guard status == noErr, let reference else { return false }
        hotKey = reference
        self.pressed = pressed
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        pressed = nil
    }

    /// Installs the application's hot-key handler once. Carbon calls it on the main thread.
    private func installHandler() -> Bool {
        guard handler == nil else { return true }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { registrar.pressed?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        return status == noErr
    }

    /// Whether macOS has `shortcut` enabled as one of its own keyboard shortcuts.
    private static func isSystemShortcut(_ shortcut: KeyShortcut) -> Bool {
        var list: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&list) == noErr, let entries = list?.takeRetainedValue() as? [[String: Any]] else { return false }
        return entries.contains { entry in
            (entry[kHISymbolicHotKeyEnabled] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode] as? Int) == Int(shortcut.keyCode)
                && (entry[kHISymbolicHotKeyModifiers] as? Int) == Int(shortcut.carbonModifiers)
        }
    }
}
