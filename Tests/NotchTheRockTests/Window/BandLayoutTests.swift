import CoreGraphics
import Testing
@testable import NotchTheRock

struct BandLayoutTests {
    /// MacBook Air M2, a virtual notch under a 24 pt menu bar, and a wider, taller notch.
    static let notches = [CGSize(width: 179, height: 32), CGSize(width: 185, height: 24), CGSize(width: 210, height: 38)]

    /// The home's 편집/완료 and gear sit in the wings of the top band, clear of the camera housing
    /// by the camera clearance, at the home's width and at the narrowest width that still holds them.
    @Test(arguments: notches)
    func R02__band_controls_stay_clear_of_the_camera(notch: CGSize) {
        let homeWidth = NotchLayout.metrics(for: .expanded, notch: notch, hasActivity: false, content: HomeGrid.size).size.width
        let narrowest = BandLayout.minimumWidth(notch: notch, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth)
        #expect(narrowest <= homeWidth, "the home is wide enough for its controls")
        for width in [homeWidth, narrowest] {
            let camera = CGRect(x: (width - notch.width) / 2, y: 0, width: notch.width, height: notch.height)
            let layout = BandLayout(notch: notch, width: width, leading: HomeChrome.editWidth, trailing: HomeChrome.gearWidth)
            #expect(layout.leadingFrame.maxX + BandLayout.cameraClearance <= camera.minX + 0.001, "leading control at \(layout.leadingFrame) under the camera \(camera)")
            #expect(layout.trailingFrame.minX - BandLayout.cameraClearance >= camera.maxX - 0.001, "trailing control at \(layout.trailingFrame) under the camera \(camera)")
            for frame in [layout.leadingFrame, layout.trailingFrame] {
                #expect(frame.minX >= NotchLayout.openShoulder && frame.maxX <= width - NotchLayout.openShoulder, "control at \(frame) leaves the shape")
                #expect(frame.minY >= 0 && frame.maxY <= notch.height, "control at \(frame) leaves the band")
            }
        }
    }
}
