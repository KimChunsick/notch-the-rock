import SwiftUI

/// How big the black shape grows for what it shows. Every presentation is measured at its own
/// (intrinsic) size and the shape keeps one padding between the content and its visible edges: the
/// side walls, which sit a shoulder radius in from the frame, the bottom, and the notch band at the
/// top. The shape is never narrower than the notch with its shoulders and never wider than the
/// home grid with its padding; content beyond that is offered `maxContentSize` and lays itself out
/// inside it. A plugin's screen under a band that makes the shape wider than the screen is offered
/// the width between the shape's paddings (`contentWidth(filling:)`), so a screen that fills it keeps
/// the same padding on every side; one that keeps its own width stays centred.
enum NotchSizing {
    static let padding: CGFloat = 20
    static let maxContentSize = CGSize(width: HomeGrid.size.width, height: 400)
    static var maxWidth: CGFloat { maxContentSize.width + 2 * (NotchLayout.openShoulder + padding) }

    /// The shape's size and where the content goes, in the shape's coordinates (origin top-left).
    struct Frame: Equatable {
        var size: CGSize
        var content: CGRect
    }

    /// Content below the notch band: home, plugin screen, attention request, takeover.
    /// - Parameter minWidth: a wider minimum, e.g. for controls in the band beside the camera.
    static func frame(
        content: CGSize,
        notch: CGSize,
        shoulder: CGFloat = NotchLayout.openShoulder,
        minWidth: CGFloat = 0
    ) -> Frame {
        let content = clamped(content)
        let narrowest = max(notch.width + 2 * shoulder, minWidth)
        let width = min(max(content.width + 2 * (shoulder + padding), narrowest), maxWidth)
        let size = CGSize(width: width, height: notch.height + content.height + 2 * padding)
        return Frame(
            size: size,
            content: CGRect(origin: CGPoint(x: (width - content.width) / 2, y: notch.height + padding), size: content)
        )
    }

    /// The content's width when it fills a shape `minWidth` wide (at most the widest shape): the
    /// width `frame(content:notch:minWidth:)` leaves between the shoulders and the padding.
    static func contentWidth(filling minWidth: CGFloat, shoulder: CGFloat = NotchLayout.openShoulder) -> CGFloat {
        max(0, min(minWidth, maxWidth) - 2 * (shoulder + padding))
    }

    private static func clamped(_ size: CGSize) -> CGSize {
        CGSize(width: max(0, min(size.width, maxContentSize.width)), height: max(0, min(size.height, maxContentSize.height)))
    }
}

/// Lays its one subview out at its own size: the ideal size, re-measured at `minWidth` when it is
/// narrower (a view that fills the offer takes it, one of a fixed width keeps its own), at the
/// maximum width when it is wider, and offered the maximum height when it is taller. The parent's
/// proposal is ignored, so the size measured here is the content's and not the shape's that holds it.
struct IntrinsicSizeLayout: Layout {
    var maxSize: CGSize
    var minWidth: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        measure(subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (size, offer) = measure(subviews)
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: offer ?? ProposedViewSize(size))
    }

    /// The size, and the proposal it was measured with when that was not the ideal one.
    private func measure(_ subviews: Subviews) -> (size: CGSize, offer: ProposedViewSize?) {
        guard let subview = subviews.first else { return (.zero, nil) }
        var offer: ProposedViewSize?
        var size = subview.sizeThatFits(.unspecified)
        if size.width < minWidth {
            offer = ProposedViewSize(width: minWidth, height: nil)
            size = subview.sizeThatFits(offer!)
        }
        if size.width > maxSize.width {
            offer = ProposedViewSize(width: maxSize.width, height: nil)
            size = subview.sizeThatFits(offer!)
        }
        if size.height > maxSize.height {
            offer = ProposedViewSize(width: min(size.width, maxSize.width), height: maxSize.height)
            size = subview.sizeThatFits(offer!)
        }
        return (CGSize(width: min(size.width, maxSize.width), height: min(size.height, maxSize.height)), offer)
    }
}
