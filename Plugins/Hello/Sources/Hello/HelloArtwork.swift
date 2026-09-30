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

    /// The handwritten word for "hello", the font outlines of `phrase` otherwise.
    init(phrase: String) {
        if phrase == HelloPhrases.hello {
            self = .hello
            return
        }
        let outline = HelloOutline.path(for: phrase)
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

    static var font: CTFont { CTFontCreateWithName(fontName as CFString, fontSize, nil) }

    /// The glyph contours of `text` in reading order, in points with y growing downward and the
    /// baseline at y 0. Glyphs the font lacks come from the font CoreText substitutes for them.
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
