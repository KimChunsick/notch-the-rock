import CoreGraphics
import Testing
@testable import NotchTheRock

struct TabBarLayoutTests {
    /// The MacBook Air M2 notch (179×32 points) in the expanded shape the app really draws.
    @Test(arguments: 1...12)
    func R02__tabs_stay_clear_of_the_camera_and_stay_reachable(tabCount: Int) {
        let notch = CGSize(width: 179, height: 32)
        let width = NotchLayout.metrics(for: .expanded, notch: notch, hasActivity: false).size.width
        let camera = CGRect(x: (width - notch.width) / 2, y: 0, width: notch.width, height: notch.height)
        let layout = TabBarLayout(notch: notch, expandedWidth: width, tabCount: tabCount)

        let controls = layout.tabFrames + [layout.overflowFrame, layout.gearFrame].compactMap { $0 }
        for (index, frame) in controls.enumerated() {
            #expect(!frame.intersects(camera), "control \(index) at \(frame) sits under the camera \(camera)")
            #expect(frame.minX >= 0 && frame.maxX <= width, "control \(index) at \(frame) leaves the shape")
            for other in controls[(index + 1)...] {
                #expect(!frame.intersects(other), "controls overlap at \(frame) and \(other)")
            }
        }
        #expect(layout.overflow == layout.tabFrames.count..<tabCount, "every tab is shown or in the overflow menu")
        #expect((layout.overflowFrame != nil) == !layout.overflow.isEmpty)
    }
}
