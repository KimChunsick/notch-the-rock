import CoreGraphics
import Testing
@testable import NotchTheRock

/// Pointer tracking with made-up pointer positions and frames (screen coordinates, origin
/// bottom-left; the MacBook Air M2 notch, screen top at y = 956).
@MainActor
struct NotchPointerTests {
    let notchRect = CGRect(x: 646, y: 924, width: 179, height: 32)

    /// The home, 264 pt tall, and a plugin screen, 124 pt tall.
    var home: NotchLayout.Metrics { NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 390, height: 200)) }
    var detail: NotchLayout.Metrics { NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 191, height: 60)) }
    var collapsed: NotchLayout.Metrics { NotchLayout.metrics(for: .collapsed, notch: notchRect.size) }

    /// A lower home row: on the home, below the plugin screen.
    var lowRow: CGPoint { CGPoint(x: notchRect.midX, y: 720) }
    var inDetail: CGPoint { CGPoint(x: notchRect.midX, y: 880) }
    var away: CGPoint { CGPoint(x: notchRect.midX, y: 600) }

    @Test func R16__a_smaller_screen_under_a_still_pointer_stays_open() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow) == .enter)
        // The row opens a smaller plugin screen; the pointer has not moved.
        #expect(pointer.handle(.shapeChanged(detail), at: lowRow) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: lowRow) == nil)
        // Only moving the pointer off the shape ends the hover.
        #expect(pointer.handle(.pointerMoved, at: CGPoint(x: lowRow.x + 4, y: lowRow.y - 3)) == .leave)

        // Nor does a shape growing under a still pointer start hovering.
        var idle = NotchPointer(notchRect: notchRect, metrics: collapsed)
        #expect(idle.handle(.shapeChanged(home), at: lowRow) == nil)
    }

    @Test func R15__hit_testing_takes_the_drawn_frame_and_the_destination_while_springing() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        // Shrinking to the plugin screen: the home is still drawn, so its lower part takes clicks.
        _ = pointer.handle(.shapeChanged(detail), at: away)
        #expect(pointer.takesMouseEvents(at: lowRow))
        #expect(pointer.takesMouseEvents(at: inDetail))
        #expect(!pointer.takesMouseEvents(at: away))
        // Settled: the plugin screen's frame alone.
        _ = pointer.handle(.shapeDrawn(detail), at: away)
        #expect(!pointer.takesMouseEvents(at: lowRow))
        #expect(pointer.takesMouseEvents(at: inDetail))
        // Growing back to the home: its frame counts before it is drawn.
        _ = pointer.handle(.shapeChanged(home), at: away)
        #expect(pointer.takesMouseEvents(at: lowRow))
        #expect(!pointer.takesMouseEvents(at: away))
    }

    @Test func R16__a_tile_drag_holds_the_notch_open_until_it_ends() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow) == .enter)
        #expect(pointer.handle(.dragBegan, at: lowRow) == .hold)
        // Dragged off the shape: no leave, and the window keeps taking mouse events.
        #expect(pointer.handle(.pointerMoved, at: away) == nil)
        #expect(pointer.takesMouseEvents(at: away))
        // Dropped or cancelled off the shape: the usual rules again.
        #expect(pointer.handle(.dragEnded, at: away) == .leave)
        #expect(!pointer.takesMouseEvents(at: away))

        // A drag dropped back on the shape keeps hovering.
        #expect(pointer.handle(.pointerMoved, at: lowRow) == .enter)
        _ = pointer.handle(.dragBegan, at: lowRow)
        _ = pointer.handle(.pointerMoved, at: away)
        #expect(pointer.handle(.dragEnded, at: lowRow) == nil)

        // A fast first drag event can leave the shape before the drag starts; the drag drops that leave.
        #expect(pointer.handle(.pointerMoved, at: away) == .leave)
        #expect(pointer.handle(.dragBegan, at: away) == .hold)
        #expect(pointer.handle(.pointerMoved, at: away) == nil)
        #expect(pointer.handle(.dragEnded, at: away) == .leave)
    }

    @Test func R16__escape_belongs_to_the_notch_only_while_its_window_is_key() {
        #expect(NotchWindowController.handlesEscape(keyCode: 53, inNotchWindow: true, notchIsKey: true, state: .expanded))
        // Settings or any other window is key: its Esc stays its own, even with the notch expanded by hover.
        #expect(!NotchWindowController.handlesEscape(keyCode: 53, inNotchWindow: false, notchIsKey: false, state: .expanded))
        #expect(!NotchWindowController.handlesEscape(keyCode: 53, inNotchWindow: false, notchIsKey: true, state: .expanded))
        #expect(!NotchWindowController.handlesEscape(keyCode: 53, inNotchWindow: true, notchIsKey: false, state: .expanded))
        // Not expanded (an attention request's text field gets Esc), or another key.
        #expect(!NotchWindowController.handlesEscape(keyCode: 53, inNotchWindow: true, notchIsKey: true, state: .attention))
        #expect(!NotchWindowController.handlesEscape(keyCode: 53, inNotchWindow: true, notchIsKey: true, state: .collapsed))
        #expect(!NotchWindowController.handlesEscape(keyCode: 36, inNotchWindow: true, notchIsKey: true, state: .expanded))
    }
}
