import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as the global hotkey is registered, stored and shown. The key is a virtual
/// key code, so the shortcut stays on the same physical key whatever input source is active.
struct KeyShortcut: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    /// The outcome of recording a key press in Settings.
    enum Recorded: Equatable {
        case shortcut(KeyShortcut)
        /// A global hotkey needs at least one of ⌘, ⌥ and ⌃.
        case needsModifier
        /// A key that has no name to show (Fn, media keys and the like).
        case unsupportedKey
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    /// ⌃⌥N: ⌃⌥Space is macOS's "select next input source" on this Mac (D-21).
    static let `default` = KeyShortcut(keyCode: UInt16(kVK_ANSI_N), modifiers: [.control, .option])

    /// The modifiers in the order macOS menus show them, then the key: "⌃⌥N".
    var display: String {
        let symbols: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        return symbols.filter { modifiers.contains($0.0) }.map(\.1).joined() + (Self.keyNames[Int(keyCode)] ?? "?")
    }

    /// The modifiers as `RegisterEventHotKey` takes them.
    var carbonModifiers: UInt32 {
        let bits: [(Modifiers, Int)] = [(.control, controlKey), (.option, optionKey), (.shift, shiftKey), (.command, cmdKey)]
        return UInt32(bits.filter { modifiers.contains($0.0) }.reduce(0) { $0 | $1.1 })
    }

    var encoded: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(encoded: Data) {
        guard let decoded = try? JSONDecoder().decode(KeyShortcut.self, from: encoded) else { return nil }
        self = decoded
    }

    /// The shortcut a key press makes, or why it cannot be one. Caps Lock, Fn and the numeric-pad
    /// flag are ignored.
    static func record(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Recorded {
        guard keyNames[Int(keyCode)] != nil else { return .unsupportedKey }
        var modifiers: Modifiers = []
        if modifierFlags.contains(.control) { modifiers.insert(.control) }
        if modifierFlags.contains(.option) { modifiers.insert(.option) }
        if modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if modifierFlags.contains(.command) { modifiers.insert(.command) }
        guard !modifiers.isDisjoint(with: [.command, .option, .control]) else { return .needsModifier }
        return .shortcut(KeyShortcut(keyCode: keyCode, modifiers: modifiers))
    }

    /// Keys a shortcut can use, by virtual key code, named as on a US keyboard.
    private static let keyNames: [Int: String] = {
        var names: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",",
            kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        ]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (index, key) in functionKeys.enumerated() { names[key] = "F\(index + 1)" }
        return names
    }()
}
