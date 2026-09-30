import CoreGraphics
import Testing
@testable import NotchTheRock

struct NotchShapeTests {
    /// The MacBook Air M2 notch; the screen's top edge is y = 956.
    let notchRect = CGRect(x: 646, y: 924, width: 179, height: 32)

    /// An external display arranged above the built-in one continues upward past y = 956.
    @Test(arguments: [NotchState.expanded, .collapsed])
    func R02__pointer_above_the_screen_is_outside_the_notch(state: NotchState) {
        let metrics = NotchLayout.metrics(for: state, notch: notchRect.size, hasActivity: false)
        #expect(!NotchLayout.contains(CGPoint(x: notchRect.midX, y: 957), metrics: metrics, notchRect: notchRect))
        #expect(!NotchLayout.contains(CGPoint(x: notchRect.midX, y: 1000), metrics: metrics, notchRect: notchRect))
        // Still inside: the very top row of the built-in screen and a point within the shape.
        #expect(NotchLayout.contains(CGPoint(x: notchRect.midX, y: 956), metrics: metrics, notchRect: notchRect))
        #expect(NotchLayout.contains(CGPoint(x: notchRect.midX, y: 940), metrics: metrics, notchRect: notchRect))
    }
}
