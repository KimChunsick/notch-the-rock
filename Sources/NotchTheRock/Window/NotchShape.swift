import SwiftUI

/// The notch outline: the top edge runs along the screen top, concave shoulders curve down into
/// the side walls, and the bottom corners are rounded.
struct NotchShape: Shape {
    var shoulderRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulderRadius, bottomRadius) }
        set {
            shoulderRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = max(0, min(shoulderRadius, rect.width / 4, rect.height / 2))
        let bottom = max(0, min(bottomRadius, (rect.width - 2 * shoulder) / 2, rect.height - shoulder))
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: left, y: rect.minY), tangent2End: CGPoint(x: left, y: rect.maxY), radius: shoulder)
        path.addArc(tangent1End: CGPoint(x: left, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.maxY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.maxY), tangent2End: CGPoint(x: right, y: rect.minY), radius: bottom)
        path.addArc(tangent1End: CGPoint(x: right, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: shoulder)
        path.closeSubpath()
        return path
    }
}

/// Size and corner radii of the black shape for each state, and where its content goes. The shape
/// hangs from the screen top, centered on the notch; the window and the pointer tracking both use
/// these numbers.
enum NotchLayout {
    struct Metrics: Equatable {
        var size: CGSize
        var shoulderRadius: CGFloat
        var bottomRadius: CGFloat
        /// Where the measured content goes, in the shape's coordinates (origin top-left).
        var content: CGRect

        var shape: NotchShape { NotchShape(shoulderRadius: shoulderRadius, bottomRadius: bottomRadius) }
    }

    /// The transparent window: the largest shape (a notch up to 44 pt tall) plus room for the
    /// attention glow.
    static let canvasSize = CGSize(
        width: NotchSizing.maxWidth + 2 * glowMargin,
        height: 44 + NotchSizing.maxContentSize.height + 2 * NotchSizing.padding + glowMargin
    )
    static let glowMargin: CGFloat = 30
    /// The widest a live activity's wing gets, its views and their insets included, so a plugin
    /// cannot widen the collapsed notch without bound: the fixed wing the measured one replaced.
    static let maxActivityWing: CGFloat = 78
    /// The widest a HUD's wing gets: room for its bar with the bar's inset on either side.
    static let maxHUDWing: CGFloat = 120
    static let collapsedShoulder: CGFloat = 6
    static let collapsedBottom: CGFloat = 10
    static let openShoulder: CGFloat = 14
    static let openBottom: CGFloat = 30

    /// What the notch height leaves above and below a live activity view's layout box, halved: the
    /// box is centred there. Below a box drawn edge to edge this is the inset its wing keeps beside
    /// and below it; `ActivityWings` adds the blank space a box keeps under its ink, so what it
    /// draws sits as far from the shape's side edge as from its bottom. Toward the camera it keeps
    /// at least as much.
    static func activityInset(contentHeight: CGFloat, notchHeight: CGFloat) -> CGFloat {
        max(0, (notchHeight - contentHeight) / 2)
    }

    /// - Parameters:
    ///   - activityWing: the width of each wing beside the camera for the live activity or the HUD,
    ///     as `ActivityWings` measures their views; 0 without one. Collapsed (at most
    ///     `maxActivityWing`) and HUD (at most `maxHUDWing`) only.
    ///   - content: the measured size of what the state shows (see `NotchSizing`); unused when
    ///     collapsed or showing a HUD.
    ///   - minWidth: a wider minimum for the expanded shape, e.g. for controls in the band.
    static func metrics(for state: NotchState, notch: CGSize, activityWing: CGFloat = 0, content: CGSize = .zero, minWidth: CGFloat = 0) -> Metrics {
        switch state {
        case .collapsed, .hud:
            // A HUD widens the collapsed notch sideways only, like a live activity.
            let wing = min(max(activityWing, 0), state == .hud ? maxHUDWing : maxActivityWing)
            let size = CGSize(width: notch.width + 2 * (collapsedShoulder + wing), height: notch.height)
            return Metrics(size: size, shoulderRadius: collapsedShoulder, bottomRadius: collapsedBottom, content: CGRect(origin: .zero, size: size))
        case .expanded, .attention, .takeover:
            let frame = NotchSizing.frame(content: content, notch: notch, minWidth: minWidth)
            return Metrics(size: frame.size, shoulderRadius: openShoulder, bottomRadius: openBottom, content: frame.content)
        }
    }

    /// The shape's frame in screen coordinates (origin bottom-left).
    static func frame(of metrics: Metrics, notchRect: CGRect) -> CGRect {
        CGRect(
            x: notchRect.midX - metrics.size.width / 2,
            y: notchRect.maxY - metrics.size.height,
            width: metrics.size.width,
            height: metrics.size.height
        )
    }

    /// Whether a screen point lies on the drawn shape (not merely in its bounding box).
    static func contains(_ point: CGPoint, metrics: Metrics, notchRect: CGRect) -> Bool {
        let frame = frame(of: metrics, notchRect: notchRect)
        // Above the frame is another display arranged over this one, not the notch.
        guard point.y <= frame.maxY else { return false }
        // Shape coordinates are flipped; the pointer at the very top row still counts as inside.
        let local = CGPoint(x: point.x - frame.minX, y: max(frame.maxY - point.y, 0.5))
        return metrics.shape.path(in: CGRect(origin: .zero, size: metrics.size)).contains(local)
    }
}
