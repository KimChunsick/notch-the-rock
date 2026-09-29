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

/// Size and corner radii of the black shape for each state. The shape hangs from the screen top,
/// centered on the notch; the window and the pointer tracking both use these numbers.
enum NotchLayout {
    struct Metrics: Equatable {
        var size: CGSize
        var shoulderRadius: CGFloat
        var bottomRadius: CGFloat

        var shape: NotchShape { NotchShape(shoulderRadius: shoulderRadius, bottomRadius: bottomRadius) }
    }

    /// The transparent window: the largest shape plus room for the attention glow.
    static let canvasSize = CGSize(width: 680, height: 340)
    static let openSize = CGSize(width: 580, height: 210)
    static let attentionSize = CGSize(width: 580, height: 300)
    static let activityWingWidth: CGFloat = 78
    static let hudWingWidth: CGFloat = 112
    static let collapsedShoulder: CGFloat = 6
    static let collapsedBottom: CGFloat = 10
    static let openShoulder: CGFloat = 14
    static let openBottom: CGFloat = 30

    static func metrics(for state: NotchState, notch: CGSize, hasActivity: Bool) -> Metrics {
        func slim(wing: CGFloat) -> Metrics {
            Metrics(
                size: CGSize(width: notch.width + 2 * (collapsedShoulder + wing), height: notch.height),
                shoulderRadius: collapsedShoulder,
                bottomRadius: collapsedBottom
            )
        }
        func open(_ size: CGSize) -> Metrics {
            Metrics(
                size: CGSize(width: max(size.width, notch.width + 2 * hudWingWidth), height: size.height),
                shoulderRadius: openShoulder,
                bottomRadius: openBottom
            )
        }
        switch state {
        case .collapsed: return slim(wing: hasActivity ? activityWingWidth : 0)
        case .hud: return slim(wing: hudWingWidth)
        case .expanded, .takeover: return open(openSize)
        case .attention: return open(attentionSize)
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
        // Shape coordinates are flipped; the pointer at the very top row still counts as inside.
        let local = CGPoint(x: point.x - frame.minX, y: max(frame.maxY - point.y, 0.5))
        return metrics.shape.path(in: CGRect(origin: .zero, size: metrics.size)).contains(local)
    }
}
