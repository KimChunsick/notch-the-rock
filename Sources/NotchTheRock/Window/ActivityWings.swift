import SwiftUI

/// The live activity's two views beside the camera. What each draws sits as far from the shape's
/// side edge as from its bottom, and at least as far from the camera; both wings are as wide as the
/// wider one needs, so the shape stays centred on the camera. Each view's layout box is centred
/// vertically, as before; its ink (`ActivityInk`) moves the inset by the blank space the box keeps
/// beside and below what it draws: a text's side bearings and the room under its baseline. A view
/// squeezed below its own size keeps the size its ink was measured at, so the blank space counted
/// is what it keeps there. Its size is always its own, the camera and both wings without the
/// shoulders, whatever it is offered: the root measures it for the shape's width.
struct ActivityWings: Layout {
    let notch: CGSize
    /// The leading and trailing views' ink, as measured at the size each is placed at; nil or
    /// missing counts the whole box as drawn.
    var ink: [ActivityInk?] = []
    /// The widest a wing gets, its view and insets included.
    var maxWing: CGFloat = NotchLayout.maxActivityWing

    /// Where a view goes in its wing: its size, the visible inset beside and below it, and the
    /// blank space its box keeps on the outer side and toward the camera.
    struct Fit {
        var size: CGSize
        var inset: CGFloat
        var outer: CGFloat
        var inner: CGFloat

        /// The wing this view needs: its ink with the inset on either side.
        var wing: CGFloat { size.width - outer - inner + 2 * inset }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let wing = subviews.prefix(2).indices.map { fit(subviews[$0], at: $0).wing }.max() ?? 0
        return CGSize(width: notch.width + 2 * min(wing, maxWing), height: notch.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for index in subviews.prefix(2).indices {
            let fit = fit(subviews[index], at: index)
            let x = index == 0 ? bounds.minX + fit.inset - fit.outer : bounds.maxX - fit.inset + fit.outer - fit.size.width
            let y = bounds.minY + NotchLayout.activityInset(contentHeight: fit.size.height, notchHeight: notch.height)
            subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(fit.size))
        }
    }

    /// A view's place and inset: at the size its ink was measured at, when that ink was measured
    /// from the view's own size as it is now; otherwise its box counts as drawn.
    private func fit(_ subview: LayoutSubview, at index: Int) -> Fit {
        let ideal = subview.sizeThatFits(.unspecified)
        guard index < ink.count, let measured = ink[index],
              abs(measured.ideal.width - ideal.width) <= 0.5, abs(measured.ideal.height - ideal.height) <= 0.5
        else { return fit(Self.placedSize(ideal: ideal, margins: EdgeInsets(), notchHeight: notch.height, maxWing: maxWing), margins: EdgeInsets(), at: index) }
        return fit(measured.size, margins: measured.margins, at: index)
    }

    /// A view placed at `size` whose box keeps `margins` blank around its ink.
    private func fit(_ size: CGSize, margins: EdgeInsets, at index: Int) -> Fit {
        Fit(
            size: size,
            inset: NotchLayout.activityInset(contentHeight: size.height, notchHeight: notch.height) + margins.bottom,
            outer: index == 0 ? margins.leading : margins.trailing,
            inner: index == 0 ? margins.trailing : margins.leading
        )
    }

    /// The size a view whose own size is `ideal` is placed at when its box keeps `margins` blank
    /// around its ink: no taller than the notch and no wider than the widest wing (`maxWing`) leaves
    /// room for. The blank sides may hang past the wing's edges, so the box can be wider than the wing.
    static func placedSize(ideal: CGSize, margins: EdgeInsets, notchHeight: CGFloat, maxWing: CGFloat = NotchLayout.maxActivityWing) -> CGSize {
        let height = min(ideal.height, notchHeight)
        let inset = NotchLayout.activityInset(contentHeight: height, notchHeight: notchHeight) + margins.bottom
        let room = maxWing - 2 * inset + margins.leading + margins.trailing
        return CGSize(width: min(ideal.width, room), height: height)
    }
}

/// The look the host gives a live activity's views, for drawing them and for measuring their ink.
struct ActivityStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .foregroundStyle(.white)
            .font(.system(size: 12, weight: .medium))
            .environment(\.colorScheme, .dark)
    }
}

/// The blank space a live activity view's layout box keeps around what it draws, beside and
/// below: text and SF Symbols carry side bearings and the room under the baseline inside their
/// boxes, and a view's alignment guides do not tell them (a symbol's text baseline also reaches
/// the art it sits in). The view is drawn offscreen at the size its wing places it at, never at its
/// own when that is larger, and the margins are read off its pixels; any pixel at least 5 % opaque
/// counts, so a faint fill does too.
struct ActivityInk: Equatable {
    /// The view's own size, laid out without drawing it, that its placed size comes from.
    var ideal: CGSize
    /// The size it is placed at and was drawn at.
    var size: CGSize
    /// Leading, trailing and bottom blank space at `size`; the top is not used, so it stays 0.
    var margins: EdgeInsets

    /// The most pixels a view is drawn with, 256 KB of RGBA. A placed box is at most twice a wing's
    /// 78 pt by a notch's height, which stays below it even at 3x; it bounds a display scale out of
    /// the ordinary.
    static let pixelBudget: CGFloat = 65_536
    /// The sizes the last measuring drew its view at, so tests can tell none was its own size.
    @MainActor static private(set) var drawn: [CGSize] = []

    /// The view's ink at the size its wing places it at. Its blank space decides that size, so it is
    /// drawn first at the size its box alone leaves room for and, when the blank space found there
    /// moves the size, once more at the new size; that second measuring is the one kept, as the
    /// size it gives moves far less. Nil when the view draws nothing (an AppKit-backed view the
    /// renderer cannot see, say) or its box is beyond the pixel budget: the box counts as drawn.
    @MainActor static func measure(_ view: AnyView, scale: CGFloat, notchHeight: CGFloat) -> ActivityInk? {
        let styled = view.modifier(ActivityStyle())
        drawn = []
        // Lays the view out without drawing it, at the display's scale as the wing does (a symbol's
        // size snaps to its pixels): the closure is handed the size and never draws.
        let layout = ImageRenderer(content: styled)
        layout.scale = scale
        var ideal = CGSize.zero
        layout.render { laidOut, _ in ideal = laidOut }
        var size = ActivityWings.placedSize(ideal: ideal, margins: EdgeInsets(), notchHeight: notchHeight)
        guard var margins = blankSpace(of: styled, at: size, scale: scale) else { return nil }
        let placed = ActivityWings.placedSize(ideal: ideal, margins: margins, notchHeight: notchHeight)
        if abs(placed.width - size.width) > 0.5, let again = blankSpace(of: styled, at: placed, scale: scale) {
            (size, margins) = (placed, again)
        }
        return ActivityInk(ideal: ideal, size: size, margins: margins)
    }

    /// The blank space around what `view` draws when its wing places it at `size`: offered that
    /// size and put at its top-leading corner, so anything it draws past the box is cut off.
    @MainActor private static func blankSpace(of view: some View, at size: CGSize, scale: CGFloat) -> EdgeInsets? {
        guard size.width * size.height * scale * scale <= pixelBudget else { return nil }
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height, alignment: .topLeading))
        renderer.scale = scale
        drawn.append(size)
        guard let image = renderer.cgImage else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] >= 13 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = y
            }
        }
        guard maxX >= 0 else { return nil }
        return EdgeInsets(
            top: 0,
            leading: CGFloat(minX) / scale,
            bottom: CGFloat(height - 1 - maxY) / scale,
            trailing: CGFloat(width - 1 - maxX) / scale
        )
    }
}
