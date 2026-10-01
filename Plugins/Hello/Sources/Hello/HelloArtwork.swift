import SwiftUI

/// A handwritten word the greeting writes: its stroke in its own canvas units, the pen that traces
/// it and the size the canvas is shown at. Trimming the shape from 0 to 1 writes the word.
struct HelloArtwork: Shape {
    /// The word as one continuous stroke in writing order.
    var stroke: Path
    /// The area the stroke is drawn in, with room around it for the pen.
    var canvas: CGRect
    /// Pen width in canvas units.
    var penWidth: CGFloat
    /// Points per canvas unit at the greeting's own size.
    var pointsPerUnit: CGFloat

    /// The handwritten "hello", at half the height it had when it filled the whole takeover.
    static let hello = HelloArtwork(
        stroke: HelloLettering.stroke,
        canvas: HelloLettering.canvas,
        penWidth: HelloLettering.strokeWidth,
        pointsPerUnit: HelloLettering.displayHeight / HelloLettering.canvas.height
    )

    /// The handwritten "안녕하세요", as tall as "hello" and written with the same pen.
    static let annyeonghaseyo = HelloArtwork(
        stroke: HangulLettering.stroke,
        canvas: HangulLettering.canvas,
        penWidth: HangulLettering.strokeWidth,
        pointsPerUnit: HangulLettering.displayHeight / HangulLettering.canvas.height
    )

    /// The words a greeting may write.
    static let words = [hello, annyeonghaseyo]

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
