import CoreGraphics

/// The hand-drawn strokes of every jamo the greetings write, in Korean stroke order: top to bottom,
/// left to right, and ㅇ from its top round to the left. Each stroke is a few points in a unit box
/// with y growing downward; the pen passes through them on a smooth curve, and a point listed twice
/// in a row is a corner it turns without lifting. Only the jamo the phrase pool needs are drawn.
enum HangulStrokes {
    /// Where a jamo sits in its syllable; consonants change shape with it.
    enum Form {
        /// The initial, left of a vertical or compound vowel.
        case beside
        /// The initial, above a horizontal vowel.
        case above
        /// The final consonant, under the rest of the syllable.
        case final
        /// A vowel, which keeps one shape and is stretched to its place.
        case vowel
    }

    /// The strokes of `jamo` in `form`, or nil if this hand has not drawn it.
    static func strokes(of jamo: Character, _ form: Form) -> [[CGPoint]]? {
        switch (jamo, form) {
        // Consonants.
        case ("ㄱ", .beside):
            [[p(0.1, 0.18), p(0.5, 0.14), p(0.86, 0.15), p(0.86, 0.15), p(0.74, 0.6), p(0.38, 0.94)]]
        case ("ㄱ", _):
            [[p(0.1, 0.2), p(0.5, 0.16), p(0.88, 0.18), p(0.88, 0.18), p(0.88, 0.55), p(0.85, 0.9)]]
        case ("ㄴ", .beside):
            [[p(0.16, 0.06), p(0.15, 0.5), p(0.2, 0.84), p(0.5, 0.9), p(0.9, 0.84)]]
        case ("ㄴ", _):
            [[p(0.14, 0.08), p(0.14, 0.62), p(0.22, 0.86), p(0.6, 0.88), p(0.92, 0.84)]]
        case ("ㄷ", _):
            [
                [p(0.14, 0.14), p(0.5, 0.11), p(0.86, 0.13)],
                [p(0.16, 0.16), p(0.15, 0.6), p(0.2, 0.86), p(0.55, 0.88), p(0.9, 0.85)],
            ]
        case ("ㄹ", _):
            [
                [p(0.14, 0.1), p(0.84, 0.08), p(0.84, 0.08), p(0.84, 0.46)],
                [p(0.16, 0.48), p(0.5, 0.47), p(0.84, 0.46)],
                [p(0.16, 0.48), p(0.16, 0.8), p(0.24, 0.9), p(0.88, 0.9)],
            ]
        case ("ㅁ", _):
            [
                [p(0.16, 0.14), p(0.15, 0.5), p(0.18, 0.88)],
                [p(0.16, 0.14), p(0.84, 0.12), p(0.84, 0.12), p(0.82, 0.88)],
                [p(0.18, 0.88), p(0.82, 0.87)],
            ]
        case ("ㅂ", _):
            [
                [p(0.18, 0.06), p(0.17, 0.5), p(0.18, 0.9)],
                [p(0.82, 0.06), p(0.81, 0.5), p(0.8, 0.9)],
                [p(0.18, 0.5), p(0.8, 0.48)],
                [p(0.18, 0.9), p(0.8, 0.9)],
            ]
        case ("ㅅ", .beside):
            [
                [p(0.56, 0.06), p(0.42, 0.52), p(0.08, 0.92)],
                [p(0.44, 0.48), p(0.66, 0.74), p(0.94, 0.9)],
            ]
        case ("ㅅ", _):
            [
                [p(0.52, 0.08), p(0.34, 0.56), p(0.06, 0.9)],
                [p(0.47, 0.4), p(0.68, 0.7), p(0.94, 0.88)],
            ]
        case ("ㅇ", _):
            [[p(0.46, 0.05), p(0.07, 0.38), p(0.24, 0.87), p(0.76, 0.87), p(0.94, 0.38), p(0.54, 0.05)]]
        case ("ㅈ", .beside):
            [
                [p(0.1, 0.14), p(0.5, 0.11), p(0.84, 0.12), p(0.84, 0.12), p(0.46, 0.58), p(0.06, 0.92)],
                [p(0.47, 0.52), p(0.68, 0.74), p(0.94, 0.9)],
            ]
        case ("ㅈ", _):
            [
                [p(0.12, 0.16), p(0.5, 0.13), p(0.86, 0.14), p(0.86, 0.14), p(0.48, 0.56), p(0.06, 0.9)],
                [p(0.5, 0.48), p(0.72, 0.72), p(0.94, 0.88)],
            ]
        case ("ㅊ", .beside):
            [
                [p(0.42, 0.0), p(0.58, 0.08)],
                [p(0.1, 0.24), p(0.5, 0.21), p(0.84, 0.22), p(0.84, 0.22), p(0.46, 0.64), p(0.06, 0.94)],
                [p(0.47, 0.58), p(0.68, 0.78), p(0.94, 0.92)],
            ]
        case ("ㅍ", _):
            [
                [p(0.1, 0.12), p(0.5, 0.1), p(0.9, 0.12)],
                [p(0.34, 0.14), p(0.32, 0.5), p(0.3, 0.84)],
                [p(0.66, 0.14), p(0.68, 0.5), p(0.7, 0.84)],
                [p(0.06, 0.86), p(0.5, 0.85), p(0.94, 0.87)],
            ]
        case ("ㅎ", .final):
            // A final has little height, so the tick and bar sit higher and the ring is larger.
            [
                [p(0.44, 0.0), p(0.56, 0.08)],
                [p(0.1, 0.2), p(0.5, 0.18), p(0.9, 0.2)],
                [p(0.47, 0.32), p(0.19, 0.56), p(0.32, 0.92), p(0.68, 0.92), p(0.81, 0.56), p(0.53, 0.32)],
            ]
        case ("ㅎ", _):
            [
                [p(0.44, 0.0), p(0.56, 0.12)],
                [p(0.12, 0.26), p(0.5, 0.24), p(0.88, 0.26)],
                [p(0.47, 0.36), p(0.21, 0.58), p(0.33, 0.91), p(0.67, 0.91), p(0.79, 0.58), p(0.53, 0.36)],
            ]
        // Vertical vowels, their stems the height of the box.
        case ("ㅏ", _):
            [[p(0.3, 0.02), p(0.28, 0.5), p(0.3, 0.98)], [p(0.31, 0.5), p(0.56, 0.47), p(0.8, 0.5)]]
        case ("ㅐ", _):
            [
                [p(0.22, 0.06), p(0.21, 0.5), p(0.23, 0.94)],
                [p(0.24, 0.5), p(0.62, 0.5)],
                [p(0.7, 0.0), p(0.69, 0.5), p(0.72, 1.0)],
            ]
        case ("ㅓ", _):
            [[p(0.14, 0.5), p(0.4, 0.48), p(0.64, 0.5)], [p(0.66, 0.02), p(0.64, 0.5), p(0.67, 0.98)]]
        case ("ㅔ", _):
            [
                [p(0.08, 0.5), p(0.42, 0.5)],
                [p(0.44, 0.08), p(0.43, 0.5), p(0.45, 0.92)],
                [p(0.76, 0.0), p(0.75, 0.5), p(0.78, 1.0)],
            ]
        case ("ㅕ", _):
            [
                [p(0.14, 0.38), p(0.4, 0.35), p(0.62, 0.37)],
                [p(0.14, 0.62), p(0.4, 0.6), p(0.62, 0.63)],
                [p(0.66, 0.02), p(0.64, 0.5), p(0.67, 0.98)],
            ]
        case ("ㅣ", _):
            [[p(0.5, 0.02), p(0.48, 0.5), p(0.51, 0.98)]]
        // Horizontal vowels, their bars the width of the box.
        case ("ㅗ", _):
            [[p(0.5, 0.2), p(0.5, 0.66)], [p(0.06, 0.7), p(0.5, 0.67), p(0.94, 0.7)]]
        case ("ㅛ", _):
            [[p(0.36, 0.22), p(0.36, 0.66)], [p(0.64, 0.22), p(0.64, 0.66)], [p(0.04, 0.7), p(0.5, 0.67), p(0.96, 0.7)]]
        case ("ㅜ", _):
            [[p(0.04, 0.28), p(0.5, 0.25), p(0.96, 0.28)], [p(0.5, 0.3), p(0.49, 0.94)]]
        case ("ㅠ", _):
            [[p(0.04, 0.28), p(0.5, 0.25), p(0.96, 0.28)], [p(0.36, 0.3), p(0.32, 0.92)], [p(0.64, 0.3), p(0.66, 0.92)]]
        case ("ㅡ", _):
            [[p(0.04, 0.55), p(0.5, 0.51), p(0.96, 0.55)]]
        default:
            nil
        }
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: y)
    }
}
