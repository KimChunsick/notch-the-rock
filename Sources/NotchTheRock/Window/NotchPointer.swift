import CoreGraphics

/// Pointer tracking of the notch window, kept apart from AppKit so it can be tested with made-up
/// pointer positions and frames: where the window takes mouse events, and when hovering starts or
/// ends.
///
/// - Only pointer events start or end hovering. A change of the shape (content of another size,
///   another state, the frame springing toward it) never does by itself.
/// - When the expanded shape shrinks (a tile opening a smaller plugin screen, back, another screen)
///   while the pointer hovers it, the old frame and `keepOpenMargin` around it stay open until the
///   pointer enters the new shape (the usual rules again), leaves that region away from the notch
///   (it hangs from the screen top around the notch), or clicks beyond it off the shape. For
///   `shrinkFloor` after the shrink, leaving is ignored so the resize cannot close it; where the
///   pointer rests when it ends (`floorEnded`) counts as a move. Once the keep-open has ended, the
///   pointer still on the larger shape drawn while it springs and off the new one closes the
///   notch when the shape settles (or at the floor's end). A notch the pointer has not entered
///   since it opened (the hotkey, a link) keeps the usual rules.
/// - While the shape springs to a new size, the window takes mouse events on the frame drawn now
///   and on the frame it is heading to; once it settles, on that frame alone.
/// - A tile drag holds the notch open, and the window takes every mouse event, until the drag ends
///   (dropped or cancelled); then the pointer is checked against the shape as after a move.
struct NotchPointer {
    enum Event {
        /// The pointer moved or dragged.
        case pointerMoved
        /// The pointer clicked.
        case clicked
        /// The shape is heading to new metrics: content of another size, or another state.
        /// `expanded`: the notch shows the home or a plugin's screen.
        case shapeChanged(NotchLayout.Metrics, expanded: Bool)
        /// The shape as drawn now, every frame while it springs toward its new metrics.
        case shapeDrawn(NotchLayout.Metrics)
        /// A tile drag in the home started.
        case dragBegan
        /// The tile drag ended, dropped or cancelled.
        case dragEnded
        /// `keepOpenFloorEnd` passed; the pointer is checked where it rests.
        case floorEnded
    }

    enum Hover: Equatable {
        /// Start hovering after the open intent.
        case enter
        /// Stop hovering after the close delay.
        case leave
        /// Drop a pending start or stop: a drag holds the notch open.
        case hold
    }

    /// How long after a shrink leaving the kept-open region is ignored.
    static let shrinkFloor: Duration = .milliseconds(600)
    /// Points around the old frame that still keep the notch open after a shrink.
    static let keepOpenMargin: CGFloat = 6

    /// The old frame kept open after a shrink, until `floorEnd` even when the pointer leaves it.
    private struct KeepOpen {
        var region: CGRect
        var floorEnd: ContinuousClock.Instant
    }

    var notchRect: CGRect
    /// The metrics the shape is heading to.
    private(set) var destination: NotchLayout.Metrics
    /// The shape as drawn now; the destination once it settles.
    private(set) var drawn: NotchLayout.Metrics
    /// Whether the pointer was on the shape at the last pointer event (or a drag holds it there).
    private var pointerInside = false
    private var isDragging = false
    private var keepOpen: KeepOpen?
    /// A shrink kept the old frame open and the shape has not settled since: see `settledCheck(at:)`.
    private var checksSettledShape = false

    init(notchRect: CGRect, metrics: NotchLayout.Metrics) {
        self.notchRect = notchRect
        destination = metrics
        drawn = metrics
    }

    /// When leaving stops being ignored after a shrink; nil while nothing is kept open.
    var keepOpenFloorEnd: ContinuousClock.Instant? { keepOpen?.floorEnd }

    /// Updates the tracking for `event` with the pointer at `pointer` (screen coordinates) at `now`
    /// and returns the hover change to schedule, if any.
    mutating func handle(_ event: Event, at pointer: CGPoint, now: ContinuousClock.Instant) -> Hover? {
        switch event {
        case .pointerMoved:
            return moved(to: pointer, now: now)
        case .clicked:
            if let keepOpen, !isOnShape(pointer), !isIn(keepOpen.region, pointer) { self.keepOpen = nil }
            return moved(to: pointer, now: now)
        case .floorEnded:
            guard keepOpen != nil else { return settledCheck(at: pointer) }
            return moved(to: pointer, now: now)
        case .shapeChanged(let metrics, let expanded):
            reshaped(to: metrics, expanded: expanded, pointer: pointer, now: now)
            return nil
        case .shapeDrawn(let metrics):
            drawn = metrics
            guard drawn == destination else { return nil }
            defer { checksSettledShape = false }
            return settledCheck(at: pointer)
        case .dragBegan:
            isDragging = true
            pointerInside = true
            return .hold
        case .dragEnded:
            isDragging = false
            return moved(to: pointer, now: now)
        }
    }

    /// Whether the window takes mouse events with the pointer at `point`.
    func takesMouseEvents(at point: CGPoint) -> Bool {
        isDragging || isOnShape(point)
    }

    /// On the shape drawn now or on the one it is heading to.
    private func isOnShape(_ point: CGPoint) -> Bool {
        NotchLayout.contains(point, metrics: drawn, notchRect: notchRect)
            || NotchLayout.contains(point, metrics: destination, notchRect: notchRect)
    }

    /// Keeps the old frame open when the expanded shape shrinks under the hovering pointer; another
    /// state ends it.
    private mutating func reshaped(to metrics: NotchLayout.Metrics, expanded: Bool, pointer: CGPoint, now: ContinuousClock.Instant) {
        let old = NotchLayout.frame(of: destination, notchRect: notchRect)
        destination = metrics
        guard expanded else {
            keepOpen = nil
            checksSettledShape = false
            return
        }
        let region = old.insetBy(dx: -Self.keepOpenMargin, dy: -Self.keepOpenMargin)
        guard !NotchLayout.frame(of: metrics, notchRect: notchRect).contains(old),
              pointerInside, !isDragging, isIn(region, pointer)
        else { return }
        // One screen change can shrink in steps; the first frame stays open.
        keepOpen = KeepOpen(region: keepOpen.map { $0.region.union(region) } ?? region, floorEnd: now + Self.shrinkFloor)
        checksSettledShape = true
    }

    /// After a shrink kept the old frame open and the keep-open ended while the larger shape was
    /// still drawn (the pointer entered the new shape, then went back onto the larger one): no move
    /// reports leaving it as it shrinks away, so the pointer off the shape now leaves.
    private mutating func settledCheck(at point: CGPoint) -> Hover? {
        guard checksSettledShape, keepOpen == nil, !isDragging, pointerInside, !isOnShape(point) else { return nil }
        pointerInside = false
        return .leave
    }

    /// In `region`, the pointer on the screen's top row included; above it is another display.
    private func isIn(_ region: CGRect, _ point: CGPoint) -> Bool {
        point.y <= notchRect.maxY && region.minX <= point.x && point.x <= region.maxX && region.minY <= point.y
    }

    private mutating func moved(to point: CGPoint, now: ContinuousClock.Instant) -> Hover? {
        guard !isDragging else { return nil }
        if let keepOpen {
            if NotchLayout.contains(point, metrics: destination, notchRect: notchRect) {
                self.keepOpen = nil
            } else if now < keepOpen.floorEnd || isIn(keepOpen.region, point) {
                return nil
            } else {
                self.keepOpen = nil
            }
        }
        let inside = isOnShape(point)
        guard inside != pointerInside else { return nil }
        pointerInside = inside
        return inside ? .enter : .leave
    }
}
