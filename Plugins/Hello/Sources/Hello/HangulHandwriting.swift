import SwiftUI

/// A Korean phrase in the plugin's own handwriting: every syllable a separate upright block put
/// together from the hand-drawn strokes of its jamo (`HangulStrokes`), never from a font. The
/// phrase wraps at spaces into centred lines that keep the greeting within its maximum width, and
/// one pen writes it stroke by stroke at a constant speed, lifting briefly between strokes.
struct HangulHandwriting {
    /// One pen-down stroke in points within `size`, smooth through its points.
    struct Stroke {
        var path: Path
        var length: CGFloat
        var start: CGPoint
    }

    /// Where the pen is: every stroke before `stroke` is written, and `fraction` of `stroke` too
    /// while the pen is down. Between strokes it is up, and `stroke` is the one it moves to.
    struct Pen: Equatable {
        var stroke: Int
        var fraction: CGFloat
        var isDown: Bool
    }

    /// Height of a syllable block in points. A line of blocks is about as tall as "hello" from its
    /// loops to its baseline (60 pt), so the ink of one line is about half the hello of before R19.
    static let syllableHeight: CGFloat = 56
    /// Handwritten blocks are a little narrower than tall and sit close together.
    static let syllableWidth: CGFloat = 48
    static let syllableGap: CGFloat = 4
    static let spaceWidth: CGFloat = 16
    static let lineGap: CGFloat = 16
    /// A thin pen, a twelfth of the block's height.
    static let penWidth: CGFloat = syllableHeight / 12
    /// Room around the blocks for the pen and the wobble of each block.
    static let margin: CGFloat = 7
    /// Points per second; "안녕하세요" takes about 1.8 s.
    static let penSpeed: CGFloat = 700
    /// The pause while the pen lifts and moves to the start of the next stroke.
    static let liftPause: TimeInterval = 0.03
    /// The widest a line of blocks may be, so the greeting with its margin and padding stays within
    /// `HelloGreeting.maxWidth`.
    static var maxLineWidth: CGFloat { HelloGreeting.maxWidth - 2 * (HelloGreeting.padding + margin) }

    /// The phrase as it wraps, top line first.
    let lines: [String]
    /// Every stroke in writing order: line by line, syllable by syllable, jamo by jamo.
    let strokes: [Stroke]
    let size: CGSize
    let syllableCount: Int

    init(_ phrase: String) {
        lines = Self.lineBreaks(for: phrase)
        let laidOut = lines.map(Self.layout(of:))
        let width = (laidOut.map(\.width).max() ?? 0) + 2 * Self.margin
        var strokes: [Stroke] = []
        var count = 0
        for (row, line) in laidOut.enumerated() {
            let left = (width - line.width) / 2
            let top = Self.margin + CGFloat(row) * (Self.syllableHeight + Self.lineGap)
            for (syllable, x) in line.syllables {
                let box = CGRect(x: left + x, y: top, width: Self.syllableWidth, height: Self.syllableHeight)
                strokes += Self.strokes(of: syllable, in: box, seed: count)
                count += 1
            }
        }
        self.strokes = strokes
        syllableCount = count
        let rows = CGFloat(lines.count)
        let height = rows * Self.syllableHeight + max(rows - 1, 0) * Self.lineGap + 2 * Self.margin
        size = CGSize(width: width, height: height)
    }

    /// Seconds the pen takes to write the phrase, pen lifts included.
    var duration: TimeInterval {
        let lifts = Double(max(strokes.count - 1, 0)) * Self.liftPause
        return strokes.reduce(0) { $0 + Double($1.length / Self.penSpeed) } + lifts
    }

    /// The pen `time` seconds after it started writing.
    func pen(at time: TimeInterval) -> Pen {
        var remaining = max(time, 0)
        for (index, stroke) in strokes.enumerated() {
            let drawing = Double(stroke.length / Self.penSpeed)
            if remaining < drawing { return Pen(stroke: index, fraction: CGFloat(remaining / drawing), isDown: true) }
            remaining -= drawing
            if index == strokes.count - 1 { break }
            if remaining < Self.liftPause { return Pen(stroke: index + 1, fraction: 0, isDown: false) }
            remaining -= Self.liftPause
        }
        return Pen(stroke: strokes.count, fraction: 0, isDown: false)
    }

    /// The ink on the page with the pen at `pen`.
    func ink(for pen: Pen) -> Path {
        var ink = Path()
        for stroke in strokes.prefix(pen.stroke) { ink.addPath(stroke.path) }
        if pen.isDown, pen.fraction > 0, strokes.indices.contains(pen.stroke) {
            ink.addPath(strokes[pen.stroke].path.trimmedPath(from: 0, to: pen.fraction))
        }
        return ink
    }

    /// Length of the ink on the page with the pen at `pen`.
    func inkedLength(for pen: Pen) -> CGFloat {
        let written = strokes.prefix(pen.stroke).reduce(0) { $0 + $1.length }
        guard pen.isDown, strokes.indices.contains(pen.stroke) else { return written }
        return written + pen.fraction * strokes[pen.stroke].length
    }

    /// The pen tip, or nil while the pen is lifted.
    func tip(for pen: Pen) -> CGPoint? {
        guard pen.isDown, strokes.indices.contains(pen.stroke) else { return nil }
        let stroke = strokes[pen.stroke]
        guard pen.fraction > 0 else { return stroke.start }
        return stroke.path.trimmedPath(from: 0, to: pen.fraction).currentPoint ?? stroke.start
    }

    /// The jamo of `phrase` this hand cannot write, by name; empty when it writes them all.
    static func missingJamo(in phrase: String) -> [String] {
        var missing: [String] = []
        for character in phrase where character != " " {
            guard let placements = placements(of: character, in: CGRect(x: 0, y: 0, width: 1, height: 1)) else {
                missing.append("\(character) is not a Hangul syllable")
                continue
            }
            for placement in placements where HangulStrokes.strokes(of: placement.jamo, placement.form) == nil {
                missing.append("\(placement.jamo) (\(placement.form)) in \(character)")
            }
        }
        return missing
    }
}

// MARK: - Lines

extension HangulHandwriting {
    /// The syllables of `line` with where each block starts, and the width of the line.
    static func layout(of line: String) -> (syllables: [(Character, CGFloat)], width: CGFloat) {
        var syllables: [(Character, CGFloat)] = []
        var x: CGFloat = 0
        var previous: Character?
        for character in line {
            if character == " " {
                x += spaceWidth
            } else {
                if let previous, previous != " " { x += syllableGap }
                syllables.append((character, x))
                x += syllableWidth
            }
            previous = character
        }
        return (syllables, x)
    }

    /// Where `phrase` breaks into lines no wider than `maxLineWidth`: at spaces, into as few lines
    /// as fit and with the widest of them as narrow as it can be, so the lines come out even rather
    /// than a long line and a lone word. A word wider than a line on its own breaks between syllables.
    static func lineBreaks(for phrase: String) -> [String] {
        // What a line may break between: the words, and the syllables of a word too wide for a line.
        // `spaced` marks a unit a space separates from the one before.
        var units: [(text: String, spaced: Bool)] = []
        for word in phrase.split(separator: " ").map(String.init) {
            if layout(of: word).width <= maxLineWidth {
                units.append((word, true))
            } else {
                units += word.enumerated().map { index, character in (String(character), index == 0) }
            }
        }
        func line(_ range: Range<Int>) -> String {
            range.map { (units[$0].spaced && $0 > range.lowerBound ? " " : "") + units[$0].text }.joined()
        }
        // Width of every run of units set as one line: `runWidths[start][count - 1]`.
        let runWidths = units.indices.map { start in (start + 1...units.count).map { layout(of: line(start..<$0)).width } }
        // Fills each line with as many units as fit within `limit`; a unit wider than that still
        // gets a line of its own.
        func fill(_ limit: CGFloat) -> [Range<Int>] {
            var lines: [Range<Int>] = []
            var start = 0
            while start < units.count {
                var count = 1
                while start + count < units.count, runWidths[start][count] <= limit { count += 1 }
                lines.append(start..<start + count)
                start += count
            }
            return lines
        }
        let fewest = fill(maxLineWidth).count
        // The narrowest run width that still fills no more lines evens the lines out.
        let limits = runWidths.joined().filter { $0 <= maxLineWidth }.sorted()
        let even = limits.lazy.map(fill).first { $0.count == fewest } ?? fill(maxLineWidth)
        return even.map(line)
    }
}

// MARK: - Syllables

extension HangulHandwriting {
    /// One jamo of a syllable and the box, in points, its unit strokes are drawn into.
    struct Placement {
        var jamo: Character
        var form: HangulStrokes.Form
        var box: CGRect
    }

    private static let initials = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    private static let medials = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    private static let finals = Array(" ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    private static let verticalVowels: Set<Character> = ["ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅣ"]
    private static let horizontalVowels: Set<Character> = ["ㅗ", "ㅛ", "ㅜ", "ㅠ", "ㅡ"]
    /// Compound vowels as their horizontal part, under the initial, and their vertical part, right.
    private static let compoundVowels: [Character: (Character, Character)] = [
        "ㅘ": ("ㅗ", "ㅏ"), "ㅙ": ("ㅗ", "ㅐ"), "ㅚ": ("ㅗ", "ㅣ"), "ㅝ": ("ㅜ", "ㅓ"),
        "ㅞ": ("ㅜ", "ㅔ"), "ㅟ": ("ㅜ", "ㅣ"), "ㅢ": ("ㅡ", "ㅣ"),
    ]
    /// Double consonants and final clusters, written as two simple consonants side by side.
    private static let pairedConsonants: [Character: (Character, Character)] = [
        "ㄲ": ("ㄱ", "ㄱ"), "ㄸ": ("ㄷ", "ㄷ"), "ㅃ": ("ㅂ", "ㅂ"), "ㅆ": ("ㅅ", "ㅅ"), "ㅉ": ("ㅈ", "ㅈ"),
        "ㄳ": ("ㄱ", "ㅅ"), "ㄵ": ("ㄴ", "ㅈ"), "ㄶ": ("ㄴ", "ㅎ"), "ㄺ": ("ㄹ", "ㄱ"), "ㄻ": ("ㄹ", "ㅁ"),
        "ㄼ": ("ㄹ", "ㅂ"), "ㄽ": ("ㄹ", "ㅅ"), "ㄾ": ("ㄹ", "ㅌ"), "ㄿ": ("ㄹ", "ㅍ"), "ㅀ": ("ㄹ", "ㅎ"),
        "ㅄ": ("ㅂ", "ㅅ"),
    ]

    /// The jamo of `syllable` placed in `box` by the syllable's shape: the initial beside a
    /// vertical vowel, above a horizontal one or in the corner of a compound one, and a final
    /// consonant under them. Nil for anything but a precomposed Hangul syllable.
    static func placements(of syllable: Character, in box: CGRect) -> [Placement]? {
        guard syllable.unicodeScalars.count == 1, let value = syllable.unicodeScalars.first?.value,
              (0xAC00...0xD7A3).contains(value) else { return nil }
        let index = Int(value - 0xAC00)
        let initial = initials[index / 588], medial = medials[index % 588 / 28], final = finals[index % 28]
        let hasFinal = final != " "
        func area(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(
                x: box.minX + x * box.width, y: box.minY + y * box.height,
                width: width * box.width, height: height * box.height
            )
        }
        var placements: [Placement] = []
        func consonant(_ jamo: Character, _ form: HangulStrokes.Form, _ area: CGRect) {
            if let (left, right) = pairedConsonants[jamo] {
                // A final pair takes the block's whole width, so each half keeps room to read.
                let area = form == .final
                    ? CGRect(x: box.minX + 0.04 * box.width, y: area.minY, width: 0.92 * box.width, height: area.height)
                    : area
                let half = CGSize(width: area.width * 0.54, height: area.height)
                let first = CGRect(origin: area.origin, size: half)
                let second = CGRect(origin: CGPoint(x: area.maxX - half.width, y: area.minY), size: half)
                placements.append(Placement(jamo: left, form: form, box: fitted(first, left)))
                placements.append(Placement(jamo: right, form: form, box: fitted(second, right)))
            } else {
                placements.append(Placement(jamo: jamo, form: form, box: fitted(area, jamo)))
            }
        }
        func vowel(_ jamo: Character, _ area: CGRect) {
            placements.append(Placement(jamo: jamo, form: .vowel, box: area))
        }
        let finalArea: CGRect
        if verticalVowels.contains(medial) {
            if hasFinal {
                consonant(initial, .beside, area(0.02, 0.02, 0.52, 0.46))
                vowel(medial, area(0.48, 0, 0.5, 0.62))
                finalArea = area(0.14, 0.62, 0.72, 0.38)
            } else {
                consonant(initial, .beside, area(0, 0.16, 0.54, 0.66))
                vowel(medial, area(0.48, 0, 0.52, 1))
                finalArea = .null
            }
        } else if horizontalVowels.contains(medial) {
            if hasFinal {
                consonant(initial, .above, area(0.2, 0, 0.6, 0.36))
                vowel(medial, area(0, 0.32, 1, 0.3))
                finalArea = area(0.16, 0.64, 0.68, 0.36)
            } else {
                consonant(initial, .above, area(0.16, 0, 0.68, 0.54))
                vowel(medial, area(0, 0.52, 1, 0.44))
                finalArea = .null
            }
        } else {
            guard let (lower, side) = compoundVowels[medial] else { return nil }
            if hasFinal {
                consonant(initial, .beside, area(0.06, 0, 0.5, 0.34))
                vowel(lower, area(0, 0.3, 0.72, 0.34))
                vowel(side, area(0.66, 0, 0.34, 0.66))
                finalArea = area(0.16, 0.66, 0.68, 0.34)
            } else {
                consonant(initial, .beside, area(0.04, 0, 0.54, 0.46))
                vowel(lower, area(0, 0.4, 0.74, 0.5))
                vowel(side, area(0.66, 0, 0.34, 1))
                finalArea = .null
            }
        }
        if hasFinal { consonant(final, .final, finalArea) }
        return placements
    }

    /// A consonant keeps close to the proportions it is drawn in: it takes its area's full height
    /// or width only so far, centred in it. ㅇ stays nearly round.
    private static func fitted(_ area: CGRect, _ jamo: Character) -> CGRect {
        let (tallest, widest): (CGFloat, CGFloat) = jamo == "ㅇ" ? (1.1, 1.15) : (1.3, 1.6)
        let height = min(area.height, area.width * tallest)
        let width = min(area.width, height * widest)
        return CGRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
    }

    /// The strokes of `syllable` in `box`, with the block tilted, shifted and sized a little and the
    /// stroke ends moved a little, all from `seed` and the syllable, so every block looks written by
    /// hand and the same phrase always comes out the same.
    private static func strokes(of syllable: Character, in box: CGRect, seed: Int) -> [Stroke] {
        guard let placements = placements(of: syllable, in: box) else { return [] }
        var wobble = Wobble(state: UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(syllable.unicodeScalars.first!.value))
        let scale = 1 + wobble.next(0.025)
        let center = CGPoint(x: box.midX + wobble.next(0.025) * box.width, y: box.midY + wobble.next(0.015) * box.height)
        let block = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: wobble.next(0.035))
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -box.midX, y: -box.midY)
        let jitter = 0.012 * box.height
        return placements.flatMap { placement in
            (HangulStrokes.strokes(of: placement.jamo, placement.form) ?? []).map { unit in
                let area = placement.box
                var points = unit.map { CGPoint(x: area.minX + $0.x * area.width, y: area.minY + $0.y * area.height) }
                for end in [0, points.count - 1] {
                    points[end].x += wobble.next(jitter)
                    points[end].y += wobble.next(jitter)
                }
                return smooth(points.map { $0.applying(block) })
            }
        }
    }

    /// A stroke through `points` on a Catmull-Rom curve drawn as cubic Béziers, a little fuller than
    /// the textbook curve (tangents 0.22 of the chord between neighbours instead of 1/6) so a loop
    /// of six points comes out round. A stroke that ends where it started, like ㅇ, is a loop and runs
    /// smoothly through its seam; any other leaves and arrives as if the curve went on. A point
    /// repeated in a row is a corner: the curve arrives along the segment before it and leaves along
    /// the next.
    private static func smooth(_ points: [CGPoint]) -> Stroke {
        let tension: CGFloat = 0.22
        let last = points.count - 1
        let xs = points.map(\.x), ys = points.map(\.y)
        let extent = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
        let loops = last >= 3 && hypot(points[last].x - points[0].x, points[last].y - points[0].y) < 0.25 * extent
        func reflected(_ end: CGPoint, _ next: CGPoint) -> CGPoint {
            CGPoint(x: 2 * end.x - next.x, y: 2 * end.y - next.y)
        }
        var path = Path()
        path.move(to: points[0])
        var length: CGFloat = 0
        for index in 0..<last where points[index] != points[index + 1] {
            let from = points[index], to = points[index + 1]
            let before = index > 0 ? points[index - 1] : loops ? points[last - 1] : reflected(from, to)
            let after = index + 1 < last ? points[index + 2] : loops ? points[1] : reflected(to, from)
            let control1 = CGPoint(x: from.x + (to.x - before.x) * tension, y: from.y + (to.y - before.y) * tension)
            let control2 = CGPoint(x: to.x - (after.x - from.x) * tension, y: to.y - (after.y - from.y) * tension)
            path.addCurve(to: to, control1: control1, control2: control2)
            length += curveLength(from, control1, control2, to)
        }
        return Stroke(path: path, length: length, start: points[0])
    }

    /// Length of a cubic Bézier, measured along 16 chords.
    private static func curveLength(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
        var length: CGFloat = 0
        var previous = p0
        for step in 1...16 {
            let t = CGFloat(step) / 16, u = 1 - t
            let point = CGPoint(
                x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
                y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
            )
            length += hypot(point.x - previous.x, point.y - previous.y)
            previous = point
        }
        return length
    }

    /// A small seeded generator (SplitMix64), so a block wobbles the same way every time.
    private struct Wobble {
        var state: UInt64

        /// A value in -range...range.
        mutating func next(_ range: CGFloat) -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (CGFloat(z >> 11) / CGFloat(UInt64(1) << 53) * 2 - 1) * range
        }
    }
}
