import SwiftUI

/// The word "hello" as one continuous handwritten stroke, drawn for this plugin from cubic Bézier
/// curves (no font outline or traced artwork). Each letter flows into the next, so trimming the
/// path from 0 to 1 writes the word the way a pen would.
struct HelloLettering: Shape {
    /// The design canvas the stroke is drawn in. `path(in:)` scales it to fit the rect it is given.
    static let canvas = CGRect(x: 0, y: 0, width: 160, height: 92)
    /// Pen width in canvas units. The stroke keeps at least this much room to every canvas edge.
    static let strokeWidth: CGFloat = 5
    /// Height of the canvas in points. Until R19 the word filled the takeover, which drew the canvas
    /// 162 pt tall under a 32 pt notch; the greeting is now half that.
    static let displayHeight: CGFloat = 81

    /// Baseline at y 80, x-height at y 55, loop tops at y 12; the letters lean forward slightly.
    static let stroke: Path = {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        var path = Path()
        // h: entry stroke sweeping up into the ascender loop, the stem, then the arch.
        path.move(to: p(10, 78))
        path.addCurve(to: p(44, 12), control1: p(24, 70), control2: p(54, 12))
        path.addCurve(to: p(28, 80), control1: p(34, 12), control2: p(31, 62))
        path.addCurve(to: p(44, 55), control1: p(31, 66), control2: p(35, 55))
        path.addCurve(to: p(52, 80), control1: p(53, 55), control2: p(46, 80))
        // e: rises into a small eye and rounds off at the baseline.
        path.addCurve(to: p(76, 56), control1: p(62, 80), control2: p(84, 60))
        path.addCurve(to: p(70, 80), control1: p(68, 52), control2: p(60, 80))
        // l l: two tall loops.
        path.addCurve(to: p(104, 12), control1: p(84, 80), control2: p(114, 16))
        path.addCurve(to: p(90, 80), control1: p(96, 8.8), control2: p(84, 80))
        path.addCurve(to: p(124, 12), control1: p(100, 80), control2: p(134, 16))
        path.addCurve(to: p(110, 80), control1: p(116, 8.8), control2: p(104, 80))
        // o: over the top, round counterclockwise, a small closing loop and a rising exit.
        path.addCurve(to: p(138, 56), control1: p(120, 80), control2: p(146, 58))
        path.addCurve(to: p(132, 80), control1: p(130, 54), control2: p(122, 80))
        path.addCurve(to: p(144, 60), control1: p(141, 80), control2: p(146, 68))
        path.addCurve(to: p(140, 54), control1: p(143.5, 58), control2: p(142, 54))
        path.addCurve(to: p(154, 52), control1: p(136, 54), control2: p(146, 58))
        return path
    }()

    /// Scale from canvas units to `rect` when the canvas is fitted into it.
    static func scale(toFit rect: CGRect) -> CGFloat {
        HelloArtwork.hello.scale(toFit: rect)
    }

    /// The stroke with its canvas fitted and centered in `rect`.
    func path(in rect: CGRect) -> Path {
        HelloArtwork.hello.path(in: rect)
    }
}
