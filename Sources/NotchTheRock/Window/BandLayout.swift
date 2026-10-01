import CoreGraphics

/// Where the controls in the top band of the expanded notch sit, in the expanded shape's
/// coordinates (origin top-left). The camera housing covers the middle of the band, so one control
/// sits in each wing: the leading one at the left edge, the trailing one at the right edge, both
/// kept `cameraClearance` away from the camera.
struct BandLayout: Equatable {
    static let controlHeight: CGFloat = 22
    /// Distance from the shape's side edge to a control: the shoulder and the content padding, so
    /// the controls line up with the content below.
    static let edgeInset: CGFloat = NotchLayout.openShoulder + NotchSizing.padding
    /// Free space kept between the controls and the camera housing.
    static let cameraClearance: CGFloat = 8

    let leadingFrame: CGRect
    let trailingFrame: CGRect

    /// - Parameters:
    ///   - width: width of the expanded shape, which is centered on the notch.
    ///   - leading: width of the control in the left wing.
    ///   - trailing: width of the control in the right wing.
    init(notch: CGSize, width: CGFloat, leading: CGFloat, trailing: CGFloat) {
        let y = (notch.height - Self.controlHeight) / 2
        leadingFrame = CGRect(x: Self.edgeInset, y: y, width: leading, height: Self.controlHeight)
        trailingFrame = CGRect(x: width - Self.edgeInset - trailing, y: y, width: trailing, height: Self.controlHeight)
    }

    /// The narrowest expanded shape whose wings hold both controls clear of the camera.
    static func minimumWidth(notch: CGSize, leading: CGFloat, trailing: CGFloat) -> CGFloat {
        notch.width + 2 * (edgeInset + max(leading, trailing) + cameraClearance)
    }
}
