import CoreGraphics
import Testing
@testable import NotchTheRock

/// Pointer tracking with made-up pointer positions and frames (screen coordinates, origin
/// bottom-left; the MacBook Air M2 notch, screen top at y = 956).
@MainActor
struct NotchPointerTests {
    let notchRect = CGRect(x: 646, y: 924, width: 179, height: 32)
    let t0 = ContinuousClock.now

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
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        // The row opens a smaller plugin screen; the pointer has not moved.
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: lowRow, now: t0) == nil)
        // Only moving the pointer ends the hover: off the shape and, after a shrink, off the old frame (R41).
        #expect(pointer.handle(.pointerMoved, at: away, now: t0 + .seconds(1)) == .leave)

        // Nor does a shape growing under a still pointer start hovering.
        var idle = NotchPointer(notchRect: notchRect, metrics: collapsed)
        #expect(idle.handle(.shapeChanged(home, expanded: true), at: lowRow, now: t0) == nil)
    }

    @Test func R15__hit_testing_takes_the_drawn_frame_and_the_destination_while_springing() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        // Shrinking to the plugin screen: the home is still drawn, so its lower part takes clicks.
        _ = pointer.handle(.shapeChanged(detail, expanded: true), at: away, now: t0)
        #expect(pointer.takesMouseEvents(at: lowRow))
        #expect(pointer.takesMouseEvents(at: inDetail))
        #expect(!pointer.takesMouseEvents(at: away))
        // Settled: the plugin screen's frame alone.
        _ = pointer.handle(.shapeDrawn(detail), at: away, now: t0)
        #expect(!pointer.takesMouseEvents(at: lowRow))
        #expect(pointer.takesMouseEvents(at: inDetail))
        // Growing back to the home: its frame counts before it is drawn.
        _ = pointer.handle(.shapeChanged(home, expanded: true), at: away, now: t0)
        #expect(pointer.takesMouseEvents(at: lowRow))
        #expect(!pointer.takesMouseEvents(at: away))
    }

    @Test func R16__a_tile_drag_holds_the_notch_open_until_it_ends() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.dragBegan, at: lowRow, now: t0) == .hold)
        // Dragged off the shape: no leave, and the window keeps taking mouse events.
        #expect(pointer.handle(.pointerMoved, at: away, now: t0) == nil)
        #expect(pointer.takesMouseEvents(at: away))
        // Dropped or cancelled off the shape: the usual rules again.
        #expect(pointer.handle(.dragEnded, at: away, now: t0) == .leave)
        #expect(!pointer.takesMouseEvents(at: away))

        // A drag dropped back on the shape keeps hovering.
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        _ = pointer.handle(.dragBegan, at: lowRow, now: t0)
        _ = pointer.handle(.pointerMoved, at: away, now: t0)
        #expect(pointer.handle(.dragEnded, at: lowRow, now: t0) == nil)

        // A fast first drag event can leave the shape before the drag starts; the drag drops that leave.
        #expect(pointer.handle(.pointerMoved, at: away, now: t0) == .leave)
        #expect(pointer.handle(.dragBegan, at: away, now: t0) == .hold)
        #expect(pointer.handle(.pointerMoved, at: away, now: t0) == nil)
        #expect(pointer.handle(.dragEnded, at: away, now: t0) == .leave)
    }

    /// The home's frame (y 692 to 956, x 510.5 to 960.5) is the region kept open after shrinking to
    /// the plugin screen (y 832 to 956, x 610 to 861); `nearLowRow` is in it, off the plugin screen.
    var nearLowRow: CGPoint { CGPoint(x: lowRow.x + 4, y: lowRow.y - 3) }

    @Test func R41__a_shrink_under_the_pointer_keeps_the_old_frame_open() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.clicked, at: lowRow, now: t0) == nil)
        // The tile opens a smaller screen in two steps (the band's width, then the measured content);
        // the floor restarts with the second and the home's frame stays the region.
        let narrower = NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 191, height: 200))
        #expect(pointer.handle(.shapeChanged(narrower, expanded: true), at: lowRow, now: t0) == nil)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0 + .milliseconds(50)) == nil)
        #expect(pointer.keepOpenFloorEnd == t0 + .milliseconds(650))
        #expect(pointer.handle(.shapeDrawn(detail), at: lowRow, now: t0 + .milliseconds(400)) == nil)
        // Off the new shape, inside the old frame: open, at the floor's end and long after it.
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(500)) == nil)
        #expect(pointer.handle(.floorEnded, at: nearLowRow, now: t0 + .milliseconds(650)) == nil)
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .seconds(2)) == nil)
        // The margin around the old frame counts; the pointer at the screen top too.
        #expect(pointer.handle(.pointerMoved, at: CGPoint(x: 963, y: 800), now: t0 + .seconds(2)) == nil)
        #expect(pointer.handle(.pointerMoved, at: CGPoint(x: 520, y: 956), now: t0 + .seconds(2)) == nil)
        // The region does not take clicks: the apps below it stay clickable.
        #expect(!pointer.takesMouseEvents(at: nearLowRow))
        // Moving away from the notch out of the old frame closes it.
        #expect(pointer.handle(.pointerMoved, at: away, now: t0 + .seconds(2)) == .leave)
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .seconds(3)) == nil)
    }

    @Test func R41__entering_the_smaller_shape_brings_back_the_usual_rules() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: lowRow, now: t0 + .milliseconds(400)) == nil)
        #expect(pointer.handle(.pointerMoved, at: inDetail, now: t0 + .seconds(1)) == nil)
        #expect(pointer.keepOpenFloorEnd == nil)
        // Leaving the new shape closes as before, though the old frame is still around the pointer.
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .seconds(1)) == .leave)
    }

    @Test func R41__an_exit_during_the_floor_waits_for_the_floor_to_end() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        // Out of the old frame while the shape still springs: ignored.
        #expect(pointer.handle(.pointerMoved, at: away, now: t0 + .milliseconds(300)) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: away, now: t0 + .milliseconds(400)) == nil)
        // Still out of it when the floor ends: closes without another move.
        #expect(pointer.handle(.floorEnded, at: away, now: t0 + .milliseconds(600)) == .leave)
        // A floor end after the keep-open ended does nothing.
        #expect(pointer.handle(.floorEnded, at: away, now: t0 + .seconds(1)) == nil)
    }

    @Test func R41__growth_and_a_notch_the_pointer_never_entered_keep_their_rules() {
        // Growing to the home: nothing is kept open, leaving the shape closes at once.
        var grown = NotchPointer(notchRect: notchRect, metrics: detail)
        #expect(grown.handle(.pointerMoved, at: inDetail, now: t0) == .enter)
        #expect(grown.handle(.shapeChanged(home, expanded: true), at: inDetail, now: t0) == nil)
        #expect(grown.keepOpenFloorEnd == nil)
        #expect(grown.handle(.pointerMoved, at: away, now: t0 + .milliseconds(100)) == .leave)

        // Opened by the hotkey or a link under a still pointer, then shrunk: nothing is kept open.
        var held = NotchPointer(notchRect: notchRect, metrics: collapsed)
        #expect(held.handle(.shapeChanged(home, expanded: true), at: lowRow, now: t0) == nil)
        #expect(held.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(held.keepOpenFloorEnd == nil)
    }

    @Test func R41__escape_and_a_click_beyond_the_old_frame_still_close() {
        // Esc collapses the notch: the old frame is no longer kept, and hovering the notch opens it again.
        var escaped = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(escaped.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(escaped.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(escaped.handle(.shapeChanged(collapsed, expanded: false), at: lowRow, now: t0 + .milliseconds(100)) == nil)
        #expect(escaped.keepOpenFloorEnd == nil)
        #expect(escaped.handle(.shapeDrawn(collapsed), at: lowRow, now: t0 + .milliseconds(300)) == nil)
        #expect(escaped.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(300)) == .leave)
        #expect(escaped.handle(.pointerMoved, at: CGPoint(x: notchRect.midX, y: 950), now: t0 + .seconds(1)) == .enter)

        // A click beyond the old frame ends the keep-open, even during the floor.
        var clicked = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(clicked.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(clicked.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(clicked.handle(.clicked, at: away, now: t0 + .milliseconds(100)) == .leave)
        #expect(clicked.keepOpenFloorEnd == nil)
    }

    @Test func R41__a_click_inside_the_old_frame_keeps_it_open() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        // A second click on the tile while the home is still drawn is on the shape.
        #expect(pointer.handle(.clicked, at: lowRow, now: t0 + .milliseconds(100)) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: lowRow, now: t0 + .milliseconds(300)) == nil)
        // Off the plugin screen, inside the home's frame: clicks there, during the floor or long after
        // it at the tile's spot, keep it open, and so does the next move.
        #expect(pointer.handle(.clicked, at: nearLowRow, now: t0 + .milliseconds(400)) == nil)
        #expect(pointer.handle(.clicked, at: lowRow, now: t0 + .seconds(2)) == nil)
        #expect(pointer.keepOpenFloorEnd != nil)
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .seconds(3)) == nil)
        #expect(pointer.handle(.pointerMoved, at: away, now: t0 + .seconds(4)) == .leave)
    }

    /// Shapes on the way from the home to the plugin screen: `nearLowRow` is on `halfway`, off
    /// `nearlyDetail` (a last frame drawn a hair off the plugin screen).
    var halfway: NotchLayout.Metrics { NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 300, height: 190)) }
    var nearlyDetail: NotchLayout.Metrics { NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 192, height: 61)) }

    @Test func R41__entering_and_leaving_the_smaller_shape_while_it_springs_closes_once_it_settles() {
        // Into the plugin screen while the home is still drawn, then back out onto the larger shape
        // drawn around it, and still: the floor's end leaves it open, the settled shape closes it.
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(pointer.handle(.pointerMoved, at: inDetail, now: t0 + .milliseconds(100)) == nil)
        #expect(pointer.handle(.shapeDrawn(halfway), at: inDetail, now: t0 + .milliseconds(150)) == nil)
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(200)) == nil)
        #expect(pointer.takesMouseEvents(at: nearLowRow))
        #expect(pointer.handle(.floorEnded, at: nearLowRow, now: t0 + .milliseconds(600)) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: nearLowRow, now: t0 + .milliseconds(700)) == .leave)
        #expect(pointer.handle(.pointerMoved, at: away, now: t0 + .seconds(1)) == nil)

        // The same, back in the plugin screen when it settles: open.
        var back = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(back.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(back.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(back.handle(.pointerMoved, at: inDetail, now: t0 + .milliseconds(100)) == nil)
        #expect(back.handle(.shapeDrawn(halfway), at: inDetail, now: t0 + .milliseconds(150)) == nil)
        #expect(back.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(200)) == nil)
        #expect(back.handle(.pointerMoved, at: inDetail, now: t0 + .milliseconds(300)) == nil)
        #expect(back.handle(.shapeDrawn(detail), at: inDetail, now: t0 + .milliseconds(400)) == nil)
        #expect(back.handle(.floorEnded, at: inDetail, now: t0 + .milliseconds(600)) == nil)

        // The last frame drawn misses the plugin screen by a hair: the floor's end closes it instead.
        var missed = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(missed.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(missed.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(missed.handle(.pointerMoved, at: inDetail, now: t0 + .milliseconds(100)) == nil)
        #expect(missed.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(200)) == nil)
        #expect(missed.handle(.shapeDrawn(nearlyDetail), at: nearLowRow, now: t0 + .milliseconds(400)) == nil)
        #expect(!missed.takesMouseEvents(at: nearLowRow))
        #expect(missed.handle(.floorEnded, at: nearLowRow, now: t0 + .milliseconds(600)) == .leave)
    }

    /// Plugin screens smaller than `detail`: `inSmaller` is on `smaller`; `offSmaller` is on `detail`,
    /// off `smaller`.
    var smaller: NotchLayout.Metrics { NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 191, height: 20)) }
    var smallest: NotchLayout.Metrics { NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 191, height: 0)) }
    var inSmaller: CGPoint { CGPoint(x: notchRect.midX, y: 900) }
    var offSmaller: CGPoint { CGPoint(x: notchRect.midX, y: 850) }

    @Test func R41__a_second_shrink_in_the_kept_region_closes_after_entering_and_leaving_the_new_shape() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: lowRow, now: t0 + .milliseconds(400)) == nil)
        #expect(pointer.handle(.floorEnded, at: lowRow, now: t0 + .milliseconds(600)) == nil)
        // The plugin screen shrinks again while the pointer rests in the home's frame; it enters the
        // new shape, goes back out onto the plugin screen still drawn around it and stops there.
        #expect(pointer.handle(.shapeChanged(smaller, expanded: true), at: lowRow, now: t0 + .seconds(1)) == nil)
        #expect(pointer.handle(.pointerMoved, at: inSmaller, now: t0 + .milliseconds(1100)) == nil)
        #expect(pointer.handle(.pointerMoved, at: offSmaller, now: t0 + .milliseconds(1200)) == nil)
        #expect(pointer.handle(.shapeDrawn(smaller), at: offSmaller, now: t0 + .milliseconds(1400)) == .leave)
    }

    @Test func R41__every_shrink_in_the_kept_region_keeps_it_and_restarts_the_floor() {
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(pointer.handle(.shapeDrawn(detail), at: lowRow, now: t0 + .milliseconds(400)) == nil)
        #expect(pointer.handle(.floorEnded, at: lowRow, now: t0 + .milliseconds(600)) == nil)
        // Second shrink, the pointer in the home's frame beyond the plugin screen's.
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .seconds(1)) == nil)
        #expect(pointer.handle(.shapeChanged(smaller, expanded: true), at: nearLowRow, now: t0 + .seconds(2)) == nil)
        #expect(pointer.keepOpenFloorEnd == t0 + .seconds(2) + NotchPointer.shrinkFloor)
        #expect(pointer.handle(.shapeDrawn(smaller), at: nearLowRow, now: t0 + .milliseconds(2400)) == nil)
        #expect(pointer.handle(.floorEnded, at: nearLowRow, now: t0 + .milliseconds(2600)) == nil)
        // Third shrink, the pointer where the plugin screen was, beyond the last shape's frame.
        #expect(pointer.handle(.pointerMoved, at: offSmaller, now: t0 + .seconds(3)) == nil)
        #expect(pointer.handle(.shapeChanged(smallest, expanded: true), at: offSmaller, now: t0 + .seconds(4)) == nil)
        #expect(pointer.keepOpenFloorEnd == t0 + .seconds(4) + NotchPointer.shrinkFloor)
        #expect(pointer.handle(.shapeDrawn(smallest), at: offSmaller, now: t0 + .milliseconds(4400)) == nil)
        #expect(pointer.handle(.floorEnded, at: offSmaller, now: t0 + .milliseconds(4600)) == nil)
        // Anywhere in the frames kept open, still open; away from the notch, closed.
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0 + .seconds(5)) == nil)
        #expect(pointer.handle(.pointerMoved, at: away, now: t0 + .seconds(6)) == .leave)
    }

    @Test func R41__a_shrink_with_the_pointer_on_the_larger_shape_still_drawn_keeps_it_open() {
        // Opened by the hotkey over the home and shrinking to the plugin screen: nothing is kept. The
        // pointer then enters on the home still drawn, beyond the plugin screen's frame, and the
        // screen shrinks again before it settles: open while the pointer stays in the frame drawn.
        var pointer = NotchPointer(notchRect: notchRect, metrics: collapsed)
        _ = pointer.handle(.shapeChanged(home, expanded: true), at: away, now: t0)
        _ = pointer.handle(.shapeDrawn(home), at: away, now: t0 + .milliseconds(300))
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: away, now: t0 + .seconds(1)) == nil)
        #expect(pointer.handle(.shapeDrawn(halfway), at: away, now: t0 + .milliseconds(1100)) == nil)
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(1150)) == .enter)
        #expect(pointer.handle(.shapeChanged(smaller, expanded: true), at: nearLowRow, now: t0 + .milliseconds(1200)) == nil)
        #expect(pointer.handle(.shapeDrawn(smaller), at: nearLowRow, now: t0 + .milliseconds(1500)) == nil)
        #expect(pointer.handle(.floorEnded, at: nearLowRow, now: t0 + .milliseconds(1800)) == nil)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0 + .seconds(3)) == nil)
        #expect(pointer.handle(.pointerMoved, at: away, now: t0 + .seconds(4)) == .leave)

        // The same, then into the new shape and back onto the home still drawn: the settled shape closes it.
        var reentered = NotchPointer(notchRect: notchRect, metrics: collapsed)
        _ = reentered.handle(.shapeChanged(home, expanded: true), at: away, now: t0)
        _ = reentered.handle(.shapeDrawn(home), at: away, now: t0 + .milliseconds(300))
        #expect(reentered.handle(.shapeChanged(detail, expanded: true), at: away, now: t0 + .seconds(1)) == nil)
        #expect(reentered.handle(.shapeDrawn(halfway), at: away, now: t0 + .milliseconds(1100)) == nil)
        #expect(reentered.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(1150)) == .enter)
        #expect(reentered.handle(.shapeChanged(smaller, expanded: true), at: nearLowRow, now: t0 + .milliseconds(1200)) == nil)
        #expect(reentered.handle(.pointerMoved, at: inSmaller, now: t0 + .milliseconds(1250)) == nil)
        #expect(reentered.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(1300)) == nil)
        #expect(reentered.handle(.shapeDrawn(smaller), at: nearLowRow, now: t0 + .milliseconds(1500)) == .leave)
    }

    /// A plugin screen taller than `detail`, still smaller than `halfway`: `inDetail` is on it,
    /// `nearLowRow` off it.
    var taller: NotchLayout.Metrics { NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 191, height: 80)) }

    @Test func R41__a_screen_growing_while_it_springs_keeps_the_kept_region_as_it_was() {
        // Into the plugin screen while the home is still drawn (nothing kept any more), then the
        // screen grows past it but not past the frame drawn; out onto the drawn frame and still:
        // nothing is kept again, and the settled shape closes it.
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(pointer.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(pointer.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(pointer.handle(.pointerMoved, at: inDetail, now: t0 + .milliseconds(100)) == nil)
        #expect(pointer.handle(.shapeDrawn(halfway), at: inDetail, now: t0 + .milliseconds(150)) == nil)
        #expect(pointer.handle(.shapeChanged(taller, expanded: true), at: inDetail, now: t0 + .milliseconds(200)) == nil)
        #expect(pointer.keepOpenFloorEnd == nil)
        #expect(pointer.handle(.pointerMoved, at: nearLowRow, now: t0 + .milliseconds(250)) == nil)
        #expect(pointer.handle(.floorEnded, at: nearLowRow, now: t0 + .milliseconds(600)) == nil)
        #expect(pointer.handle(.shapeDrawn(taller), at: nearLowRow, now: t0 + .milliseconds(700)) == .leave)

        // Growing while the home's frame is still kept: kept as it was, the floor not restarted.
        var kept = NotchPointer(notchRect: notchRect, metrics: home)
        #expect(kept.handle(.pointerMoved, at: lowRow, now: t0) == .enter)
        #expect(kept.handle(.shapeChanged(detail, expanded: true), at: lowRow, now: t0) == nil)
        #expect(kept.handle(.shapeChanged(taller, expanded: true), at: lowRow, now: t0 + .milliseconds(200)) == nil)
        #expect(kept.keepOpenFloorEnd == t0 + NotchPointer.shrinkFloor)
        #expect(kept.handle(.shapeDrawn(taller), at: lowRow, now: t0 + .milliseconds(400)) == nil)
        #expect(kept.handle(.floorEnded, at: lowRow, now: t0 + .milliseconds(600)) == nil)
        #expect(kept.handle(.pointerMoved, at: away, now: t0 + .seconds(1)) == .leave)
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
