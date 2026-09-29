import CoreGraphics
import Testing
@testable import NotchTheRock

struct NotchGeometryTests {
    /// Values `NSScreen` reports on a MacBook Air M2 (1470×956 points, notch).
    @Test func R02__notch_rect_between_auxiliary_top_areas() {
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
            menuBarHeight: 33,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 0, y: 924, width: 646, height: 32),
            auxiliaryTopRightArea: CGRect(x: 825, y: 924, width: 645, height: 32)
        )
        #expect(geometry.hasHardwareNotch)
        #expect(geometry.notchRect == CGRect(x: 646, y: 924, width: 179, height: 32))
    }

    /// The built-in display arranged right of a main display: the notch follows the screen origin.
    @Test func R02__notch_rect_follows_screen_origin() {
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 1920, y: -200, width: 1470, height: 956),
            menuBarHeight: 33,
            safeAreaTop: 32,
            auxiliaryTopLeftArea: CGRect(x: 1920, y: 724, width: 646, height: 32),
            auxiliaryTopRightArea: CGRect(x: 2745, y: 724, width: 645, height: 32)
        )
        #expect(geometry.notchRect == CGRect(x: 2566, y: 724, width: 179, height: 32))
    }

    @Test func R02__virtual_notch_at_top_center_without_notch() {
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            menuBarHeight: 24,
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        let width = NotchGeometry.virtualNotchWidth
        #expect(!geometry.hasHardwareNotch)
        #expect(geometry.notchRect == CGRect(x: (1920 - width) / 2, y: 1056, width: width, height: 24))
    }

    /// A hidden menu bar leaves no height to copy, so the virtual notch keeps its default height.
    @Test func R02__virtual_notch_keeps_height_when_menu_bar_hidden() {
        let geometry = NotchGeometry(
            screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            menuBarHeight: 0,
            safeAreaTop: 0,
            auxiliaryTopLeftArea: nil,
            auxiliaryTopRightArea: nil
        )
        #expect(geometry.notchRect.height == NotchGeometry.virtualNotchHeight)
        #expect(geometry.notchRect.maxY == 1080)
    }
}
