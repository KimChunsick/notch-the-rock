import CoreGraphics
import Testing
@testable import NotchTheRock

struct NotchSizingTests {
    let notch = CGSize(width: 179, height: 32)
    let shoulder = NotchLayout.openShoulder
    let padding = NotchSizing.padding

    /// Space between the content and the shape's visible edges: its side walls (inset by the
    /// shoulder curve), the bottom, and the notch band at the top.
    func paddings(_ frame: NotchSizing.Frame) -> [CGFloat] {
        [
            frame.content.minX - shoulder,
            frame.size.width - shoulder - frame.content.maxX,
            frame.content.minY - notch.height,
            frame.size.height - frame.content.maxY,
        ]
    }

    @Test func R15__two_content_sizes_give_two_frames_with_equal_padding() {
        let contents = [CGSize(width: 191, height: 108), CGSize(width: 390, height: 230)]
        let a = NotchSizing.frame(content: contents[0], notch: notch)
        let b = NotchSizing.frame(content: contents[1], notch: notch)
        #expect(a.size != b.size)
        for (frame, content) in zip([a, b], contents) {
            for value in paddings(frame) {
                #expect(abs(value - padding) <= 0.5, "padding \(value) in \(frame)")
            }
            #expect(frame.content.size == content)
        }
        #expect(a.size == CGSize(width: 191 + 2 * (shoulder + padding), height: notch.height + 108 + 2 * padding))
    }

    @Test func R15__never_narrower_than_the_notch_shape_and_never_wider_than_the_home() {
        let tiny = NotchSizing.frame(content: CGSize(width: 20, height: 10), notch: notch)
        #expect(tiny.size.width == notch.width + 2 * shoulder)
        // Content narrower than the minimum is centered; top and bottom keep the padding.
        #expect(abs(tiny.content.midX - tiny.size.width / 2) <= 0.5)
        #expect(tiny.content.minY == notch.height + padding)
        #expect(tiny.size.height - tiny.content.maxY == padding)

        let huge = NotchSizing.frame(content: CGSize(width: 1000, height: 1000), notch: notch)
        #expect(huge.size.width == NotchSizing.maxWidth)
        #expect(NotchSizing.maxWidth == HomeGrid.size.width + 2 * (shoulder + padding))
        #expect(huge.content.size == NotchSizing.maxContentSize)
        for value in paddings(huge) {
            #expect(abs(value - padding) <= 0.5)
        }

        // A wider minimum (room for the band controls) also centers the content.
        let wide = NotchSizing.frame(content: CGSize(width: 100, height: 40), notch: notch, minWidth: 300)
        #expect(wide.size.width == 300)
        #expect(abs(wide.content.midX - 150) <= 0.5)
    }

    /// The margin is 18 pt (D-58) on the left, the right and the bottom and under the notch band,
    /// for the home and plugin screens, alerts and takeovers such as the greeting alike: the shape is
    /// the content plus the shoulders and two margins wide and the band, the content and two margins tall.
    @Test func R15__the_expanded_margin_is_18_pt_for_every_open_presentation() {
        #expect(NotchSizing.padding == 18)
        let content = CGSize(width: 191, height: 108)
        for state in [NotchState.expanded, .attention, .takeover] {
            let metrics = NotchLayout.metrics(for: state, notch: notch, content: content)
            #expect(metrics.size == CGSize(width: 191 + 2 * (shoulder + 18), height: 32 + 108 + 2 * 18), "\(state)")
            #expect(metrics.content == CGRect(x: shoulder + 18, y: 32 + 18, width: 191, height: 108), "\(state)")
        }
        #expect(NotchSizing.maxWidth == HomeGrid.size.width + 2 * (shoulder + 18))
        // A plugin's screen under a wider band is offered the band's width less the shoulders and margins.
        #expect(NotchSizing.contentWidth(filling: 300) == 300 - 2 * (shoulder + 18))
        // The band's back control and gear keep the same distance from the side walls as the content.
        #expect(BandLayout.edgeInset == shoulder + 18)
    }

    /// The collapsed notch's live-activity wings and the HUD take their insets from the notch's
    /// height, not from the expanded margin.
    @Test func R15__the_expanded_margin_leaves_the_collapsed_wings_and_the_hud_alone() {
        #expect(NotchLayout.metrics(for: .collapsed, notch: notch).size == CGSize(width: 179 + 2 * 6, height: 32))
        let activity = NotchLayout.metrics(for: .collapsed, notch: notch, activityWing: 50)
        #expect(activity.size == CGSize(width: 179 + 2 * (6 + 50), height: 32))
        #expect(activity.content == CGRect(x: 0, y: 0, width: 179 + 2 * (6 + 50), height: 32))
        let hud = NotchLayout.metrics(for: .hud, notch: notch, activityWing: 100)
        #expect(hud.size == CGSize(width: 179 + 2 * (6 + 100), height: 32))
        #expect(hud.content == CGRect(x: 0, y: 0, width: 179 + 2 * (6 + 100), height: 32))
        #expect(NotchLayout.activityInset(contentHeight: 14, notchHeight: 32) == 9)
        #expect(NotchLayout.activityInset(contentHeight: 22, notchHeight: 37) == 7.5)
    }

    /// A HUD keeps the collapsed notch's height and corners and widens it sideways by its wings,
    /// up to the HUD's widest wing.
    @Test func R25__hud_widens_the_collapsed_notch_sideways_only() {
        let collapsed = NotchLayout.metrics(for: .collapsed, notch: notch)
        let hud = NotchLayout.metrics(for: .hud, notch: notch, activityWing: 100, content: CGSize(width: 300, height: 200))
        #expect(hud.size == CGSize(width: collapsed.size.width + 200, height: notch.height))
        #expect(hud.content == CGRect(origin: .zero, size: hud.size))
        #expect(hud.shoulderRadius == collapsed.shoulderRadius && hud.bottomRadius == collapsed.bottomRadius)
        let widest = NotchLayout.metrics(for: .hud, notch: notch, activityWing: 1000)
        #expect(widest.size.width == collapsed.size.width + 2 * NotchLayout.maxHUDWing)
    }

    /// R02 geometry holds for every content size: the top edge is the screen top at the notch and
    /// the shape is centered on the notch, with and without a hardware notch.
    @Test(arguments: [
        NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956), menuBarHeight: 33, safeAreaTop: 32,
                      auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
                      auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)),
        NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080), menuBarHeight: 24, safeAreaTop: 0,
                      auxiliaryTopLeftArea: nil, auxiliaryTopRightArea: nil),
    ])
    func R15__frames_hang_from_the_notch_and_stay_centered(geometry: NotchGeometry) {
        let notchRect = geometry.notchRect
        for content in [CGSize(width: 191, height: 108), CGSize(width: 390, height: 230)] {
            for state in [NotchState.expanded, .attention, .takeover, .hud] {
                let metrics = NotchLayout.metrics(for: state, notch: notchRect.size, content: content)
                let frame = NotchLayout.frame(of: metrics, notchRect: notchRect)
                #expect(frame.maxY == geometry.screenFrame.maxY)
                #expect(abs(frame.midX - notchRect.midX) <= 0.5)
            }
        }
    }

    /// Pointer tracking uses the measured frame: a point below a small presentation is outside
    /// it and inside a taller one.
    @Test func R15__hit_testing_follows_the_measured_frame() {
        let notchRect = CGRect(x: 646, y: 924, width: 179, height: 32)
        let small = NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 191, height: 60))
        let tall = NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 191, height: 200))
        let point = CGPoint(x: notchRect.midX, y: notchRect.maxY - small.size.height - 20)
        #expect(!NotchLayout.contains(point, metrics: small, notchRect: notchRect))
        #expect(NotchLayout.contains(point, metrics: tall, notchRect: notchRect))
    }
}
