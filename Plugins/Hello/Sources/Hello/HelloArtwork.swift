import CoreText
import SwiftUI

/// What the greeting writes: a stroke in its own canvas units, the pen that traces it and the size
/// the canvas is shown at. Trimming the shape from 0 to 1 writes the phrase.
struct HelloArtwork: Shape {
    /// Every subpath in writing order. A trim runs along them one after another.
    var stroke: Path
    /// The area the stroke is drawn in, with room around it for the pen.
    var canvas: CGRect
    /// Pen width in canvas units.
    var penWidth: CGFloat
    /// Points per canvas unit at the greeting's own size.
    var pointsPerUnit: CGFloat
    /// Outlined letters fill in once their outlines are written; the handwritten word stays a line.
    var fillsWhenWritten: Bool

    /// The handwritten "hello", at half the height it had when it filled the whole takeover.
    static let hello = HelloArtwork(
        stroke: HelloLettering.stroke,
        canvas: HelloLettering.canvas,
        penWidth: HelloLettering.strokeWidth,
        pointsPerUnit: HelloLettering.displayHeight / HelloLettering.canvas.height,
        fillsWhenWritten: false
    )

    /// The handwritten word for "hello", which never wraps. Any other phrase is its font outlines,
    /// wrapped into centred lines and written line by line.
    init(phrase: String) {
        if phrase == HelloPhrases.hello {
            self = .hello
            return
        }
        var outline = Path()
        for line in HelloOutline.lines(for: phrase) {
            outline.addPath(line.stroke)
        }
        self.init(
            stroke: outline,
            canvas: outline.boundingRect.insetBy(dx: -HelloOutline.margin, dy: -HelloOutline.margin),
            penWidth: HelloOutline.penWidth,
            pointsPerUnit: 1,
            fillsWhenWritten: true
        )
    }

    init(stroke: Path, canvas: CGRect, penWidth: CGFloat, pointsPerUnit: CGFloat, fillsWhenWritten: Bool) {
        self.stroke = stroke
        self.canvas = canvas
        self.penWidth = penWidth
        self.pointsPerUnit = pointsPerUnit
        self.fillsWhenWritten = fillsWhenWritten
    }

    /// The greeting's own size in points.
    var size: CGSize {
        CGSize(width: canvas.width * pointsPerUnit, height: canvas.height * pointsPerUnit)
    }

    /// Scale from canvas units to `rect` when the canvas is fitted into it.
    func scale(toFit rect: CGRect) -> CGFloat {
        min(rect.width / canvas.width, rect.height / canvas.height)
    }

    /// The stroke with its canvas fitted and centered in `rect`.
    func path(in rect: CGRect) -> Path {
        let scale = scale(toFit: rect)
        let transform = CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - canvas.midX * scale,
            ty: rect.midY - canvas.midY * scale
        )
        return stroke.applying(transform)
    }
}

/// A phrase set in Apple SD Gothic Neo SemiBold, which ships with every macOS since 10.8 and covers
/// Hangul and Latin, turned into its glyph outlines.
enum HelloOutline {
    static let fontName = "AppleSDGothicNeo-SemiBold"
    /// Hangul glyphs at this size are about 63 pt tall, as tall as the handwritten "hello" at its
    /// halved size.
    static let fontSize: CGFloat = 70
    static let penWidth: CGFloat = 2.2
    /// Room around the outlines for the pen and its tip, in points.
    static let margin: CGFloat = 8
    /// The widest a line of letters may be, about two and a half times the handwritten "hello": a
    /// longer phrase wraps onto further lines, so a greeting never widens the notch past this.
    static let maxLineWidth: CGFloat = 360
    /// Baseline to baseline between wrapped lines. Hangul glyphs are about 62 pt tall, which leaves
    /// about 18 pt between the letters of one line and the next.
    static let lineSpacing: CGFloat = 80

    static var font: CTFont { CTFontCreateWithName(fontName as CFString, fontSize, nil) }

    /// One line of a wrapped phrase and its glyph contours, placed where the phrase draws them.
    struct Line {
        var text: String
        var stroke: Path
    }

    /// `text` in lines no wider than `maxLineWidth`, top line first: each line keeps the size of a
    /// single line, sits `lineSpacing` below the one before and is centred on x 0.
    static func lines(for text: String) -> [Line] {
        lineBreaks(for: text).enumerated().map { index, line in
            let outline = path(for: line)
            return Line(text: line, stroke: outline.offsetBy(dx: -outline.boundingRect.midX, dy: CGFloat(index) * lineSpacing))
        }
    }

    /// Where `text` breaks into lines no wider than `maxLineWidth`: at spaces, into as few lines as
    /// fit and with the widest of them as narrow as it can be, so the lines come out even rather than
    /// a long line and a lone word. A word wider than a line on its own breaks between characters.
    static func lineBreaks(for text: String) -> [String] {
        // What a line may break between: the words, and the characters of a word too wide for a
        // line. `spaced` marks a unit a space separates from the one before.
        var units: [(text: String, spaced: Bool)] = []
        for word in text.split(separator: " ").map(String.init) {
            if width(of: word) <= maxLineWidth {
                units.append((word, true))
            } else {
                units += word.enumerated().map { index, character in (String(character), index == 0) }
            }
        }
        func line(_ range: Range<Int>) -> String {
            range.map { (units[$0].spaced && $0 > range.lowerBound ? " " : "") + units[$0].text }.joined()
        }
        // Ink width of every run of units set as one line: `runWidths[start][count - 1]`.
        let runWidths = units.indices.map { start in (start + 1...units.count).map { width(of: line(start..<$0)) } }
        // Fills each line with as many units as fit within `limit`; a unit wider than that still gets
        // a line of its own.
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

    /// Width of the ink of `text` set on a single line.
    static func width(of text: String) -> CGFloat {
        path(for: text).boundingRect.width
    }

    /// The glyph contours of `text` on a single line in reading order, in points with y growing
    /// downward and the baseline at y 0. Glyphs the font lacks come from the font CoreText
    /// substitutes for them.
    static func path(for text: String) -> Path {
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        let string = CFAttributedStringCreate(nil, text as CFString, attributes)!
        let line = CTLineCreateWithAttributedString(string)
        let outline = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                // A space has no outline.
                guard let glyphPath = CTFontCreatePathForGlyph(runFont, glyph, nil) else { continue }
                // CoreText's y grows upward; flip it about the baseline.
                outline.addPath(glyphPath, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: position.x, ty: -position.y))
            }
        }
        return Path(outline)
    }
}
