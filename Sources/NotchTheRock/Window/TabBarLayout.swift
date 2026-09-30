import CoreGraphics

/// Where the controls of the expanded notch's top row sit, in the expanded shape's coordinates
/// (origin top-left). The camera housing covers the middle of that row, so tabs stay in the left
/// wing and the gear in the right wing; tabs that do not fit go behind one overflow control.
struct TabBarLayout: Equatable {
    static let buttonSize = CGSize(width: 26, height: 22)
    static let spacing: CGFloat = 4
    /// Distance from the shape's side edge to the outermost control.
    static let edgeInset: CGFloat = NotchLayout.openShoulder + 14
    /// Free space kept between the controls and the camera housing.
    static let cameraClearance: CGFloat = 8

    /// Frames of the tabs shown in the bar, for tabs `0..<tabFrames.count`.
    let tabFrames: [CGRect]
    /// Tabs reachable only through the overflow control.
    let overflow: Range<Int>
    /// The overflow control, present exactly when `overflow` is not empty.
    let overflowFrame: CGRect?
    let gearFrame: CGRect

    /// - Parameter expandedWidth: width of the expanded shape, which is centered on the notch.
    init(notch: CGSize, expandedWidth: CGFloat, tabCount: Int) {
        let size = Self.buttonSize
        let y = (notch.height - size.height) / 2
        func slot(_ index: Int) -> CGRect {
            CGRect(x: Self.edgeInset + CGFloat(index) * (size.width + Self.spacing), y: y, width: size.width, height: size.height)
        }
        let leftWing = (expandedWidth - notch.width) / 2 - Self.cameraClearance - Self.edgeInset
        let slots = max(0, Int(((leftWing + Self.spacing) / (size.width + Self.spacing)).rounded(.down)))
        // When the tabs do not all fit, the last slot holds the overflow control instead.
        let shown = tabCount <= slots ? tabCount : max(0, slots - 1)
        tabFrames = (0..<shown).map(slot)
        overflow = shown..<tabCount
        overflowFrame = overflow.isEmpty ? nil : slot(shown)
        gearFrame = CGRect(x: expandedWidth - Self.edgeInset - size.width, y: y, width: size.width, height: size.height)
    }
}
