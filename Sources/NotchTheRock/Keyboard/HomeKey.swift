import AppKit

/// A key press the expanded notch acts on, taken from a key event apart from AppKit so it can be
/// tested with made-up key codes.
enum HomeKey: Equatable {
    case up
    case down
    case left
    case right
    case enter
    case escape
    case backspace
    /// Letters or digits typed without ⌘, ⌃ or ⌥: they start or feed the quick search.
    case text(String)

    /// Nil for keys the notch leaves alone: shortcuts with ⌘, ⌃ or ⌥, and keys that are neither
    /// navigation nor letters or digits (space, Tab, punctuation).
    init?(keyCode: UInt16, characters: String?, modifierFlags: NSEvent.ModifierFlags) {
        guard modifierFlags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch keyCode {
        case 126: self = .up
        case 125: self = .down
        case 123: self = .left
        case 124: self = .right
        case 36, 76: self = .enter
        case 53: self = .escape
        case 51: self = .backspace
        default:
            guard let characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return nil }
            self = .text(characters)
        }
    }
}
