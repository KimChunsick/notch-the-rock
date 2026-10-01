import CoreGraphics

/// Pointer tracking of the notch window, kept apart from AppKit so it can be tested with made-up
/// pointer positions and frames: where the window takes mouse events, and when hovering starts or
/// ends.
///
/// - Only pointer events start or end hovering. A change of the shape (content of another size,
///   another state, the frame springing toward it) never does by itself, so a smaller plugin screen
///   opened under a still pointer stays open until the pointer moves.
/// - While the shape springs to a new size, the window takes mouse events on the frame drawn now
///   and on the frame it is heading to; once it settles, on that frame alone.
/// - A tile drag holds the notch open, and the window takes every mouse event, until the drag ends
///   (dropped or cancelled); then the pointer is checked against the shape as after a move.
struct NotchPointer {
    enum Event {
        /// The pointer moved, dragged or clicked.
        case pointerMoved
        /// The shape is heading to new metrics: content of another size, or another state.
        case shapeChanged(NotchLayout.Metrics)
        /// The shape as drawn now, every frame while it springs toward its new metrics.
        case shapeDrawn(NotchLayout.Metrics)
        /// A tile drag in the home started.
        case dragBegan
        /// The tile drag ended, dropped or cancelled.
        case dragEnded
    }

    enum Hover: Equatable {
        /// Start hovering after the open intent.
        case enter
        /// Stop hovering after the close delay.
        case leave
        /// Drop a pending start or stop: a drag holds the notch open.
        case hold
    }

    var notchRect: CGRect
    /// The metrics the shape is heading to.
    private(set) var destination: NotchLayout.Metrics
    /// The shape as drawn now; the destination once it settles.
    private(set) var drawn: NotchLayout.Metrics
    /// Whether the pointer was on the shape at the last pointer event (or a drag holds it there).
    private var pointerInside = false
    private var isDragging = false

    init(notchRect: CGRect, metrics: NotchLayout.Metrics) {
        self.notchRect = notchRect
        destination = metrics
        drawn = metrics
    }

    /// Updates the tracking for `event` with the pointer at `pointer` (screen coordinates) and
    /// returns the hover change to schedule, if any.
    mutating func handle(_ event: Event, at pointer: CGPoint) -> Hover? {
        switch event {
        case .pointerMoved:
            return moved(to: pointer)
        case .shapeChanged(let metrics):
            destination = metrics
            return nil
        case .shapeDrawn(let metrics):
            drawn = metrics
            return nil
        case .dragBegan:
            isDragging = true
            pointerInside = true
            return .hold
        case .dragEnded:
            isDragging = false
            return moved(to: pointer)
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

    private mutating func moved(to point: CGPoint) -> Hover? {
        guard !isDragging else { return nil }
        let inside = isOnShape(point)
        guard inside != pointerInside else { return nil }
        pointerInside = inside
        return inside ? .enter : .leave
    }
}
