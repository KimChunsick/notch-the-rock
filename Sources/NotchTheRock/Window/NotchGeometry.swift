import AppKit

/// Where the notch is on a screen, in global screen coordinates (origin bottom-left).
///
/// On a screen with a camera housing the notch spans the gap between `auxiliaryTopLeftArea` and
/// `auxiliaryTopRightArea` and is `safeAreaInsets.top` tall. On any other screen a virtual notch of
/// the same shape sits at the top center, as tall as the menu bar.
struct NotchGeometry: Equatable {
    static let virtualNotchWidth: CGFloat = 185
    /// Height of the virtual notch when the screen has no visible menu bar to match.
    static let virtualNotchHeight: CGFloat = 24

    let screenFrame: CGRect
    let notchRect: CGRect
    let hasHardwareNotch: Bool

    /// Only the widths of the auxiliary areas are used, so the result does not depend on whether
    /// they are given in global or screen-local coordinates.
    init(
        screenFrame: CGRect,
        menuBarHeight: CGFloat,
        safeAreaTop: CGFloat,
        auxiliaryTopLeftArea: CGRect?,
        auxiliaryTopRightArea: CGRect?
    ) {
        self.screenFrame = screenFrame
        if let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea, safeAreaTop > 0,
           screenFrame.width - left.width - right.width > 0 {
            hasHardwareNotch = true
            notchRect = CGRect(
                x: screenFrame.minX + left.width,
                y: screenFrame.maxY - safeAreaTop,
                width: screenFrame.width - left.width - right.width,
                height: safeAreaTop
            )
        } else {
            let height = menuBarHeight > 0 ? menuBarHeight : Self.virtualNotchHeight
            hasHardwareNotch = false
            notchRect = CGRect(
                x: screenFrame.midX - Self.virtualNotchWidth / 2,
                y: screenFrame.maxY - height,
                width: Self.virtualNotchWidth,
                height: height
            )
        }
    }

    init(screen: NSScreen) {
        self.init(
            screenFrame: screen.frame,
            menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea,
            auxiliaryTopRightArea: screen.auxiliaryTopRightArea
        )
    }

    /// The built-in display when there is one (the notch lives there), otherwise the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number.map { CGDisplayIsBuiltin(CGDirectDisplayID($0.uint32Value)) != 0 } ?? false
        } ?? NSScreen.screens.first
    }
}
