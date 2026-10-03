import CoreGraphics

/// A brightness key, by its `NX_KEYTYPE_*` code. The volume and mute keys (0, 1 and 7) belong to
/// the volume plugin.
enum MediaKey: Int, Hashable, Sendable {
    case brightnessUp = 2
    case brightnessDown = 3
}

/// What the event tap hands over from an `NX_SYSDEFINED` event: its subtype, `data1` and modifier
/// flags.
struct SystemDefinedEvent: Sendable {
    let subtype: Int
    let data1: Int
    let flags: CGEventFlags
}

/// A press or release of one of the keys in `MediaKey`, decoded from an `NX_SYSDEFINED` event of
/// subtype 8 (`NX_SUBTYPE_AUX_CONTROL_BUTTONS`). Every other event decodes to nil, so the plugin
/// passes it on: the media keys `MediaKey` leaves out, such as play/pause, next and previous (key
/// codes 16–20), which belong to other plugins.
struct MediaKeyPress: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case down
        case up
    }

    static let auxControlButtonsSubtype = 8

    let key: MediaKey
    let state: State
    /// Auto-repeat of a held key. Comes with `state == .down`.
    let isRepeat: Bool
}

extension MediaKeyPress {
    /// `data1` holds the key code in bits 16–31, the key state in bits 8–15 (0xA down, 0xB up) and
    /// the repeat flag in bit 0.
    init?(subtype: Int, data1: Int) {
        guard subtype == Self.auxControlButtonsSubtype,
              let key = MediaKey(rawValue: (data1 & 0xFFFF_0000) >> 16)
        else { return nil }
        switch (data1 & 0xFF00) >> 8 {
        case 0xA: state = .down
        case 0xB: state = .up
        default: return nil
        }
        self.key = key
        isRepeat = data1 & 0x1 != 0
    }
}
