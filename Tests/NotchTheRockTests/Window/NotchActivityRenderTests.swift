import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// The collapsed notch with a live activity, drawn offscreen by the app's own root view: each view
/// beside the camera keeps as much space to the shape's side edge as to its bottom. The root package
/// cannot import the plugins, so each activity is a stand-in: opaque rectangles of the sizes the
/// plugin's views lay out at (NowPlaying's 22 pt album art and 18 x 14 pt bars, Battery's symbol and
/// percentage measured here), which the ink measurement sees edge to edge.
@MainActor
@Suite struct NotchActivityRenderTests {
    /// Blue like the menu bar around the shape. Its red channel is zero, so ink is told apart from it
    /// and from the black by red alone.
    static let backdrop = Color(red: 0, green: 0.2, blue: 1)
    nonisolated static let notchWidth: CGFloat = 185

    struct Insets: CustomStringConvertible {
        var leftSide: CGFloat
        var leftBottom: CGFloat
        var leftCamera: CGFloat
        var rightSide: CGFloat
        var rightBottom: CGFloat
        var rightCamera: CGFloat
        /// The shape's side edges from the camera's centre: equal when the shape is centred.
        var leftHalf: CGFloat
        var rightHalf: CGFloat

        var description: String {
            String(format: "left wing: side %.1f bottom %.1f camera %.1f; right wing: side %.1f bottom %.1f camera %.1f; halves %.1f / %.1f pt",
                   leftSide, leftBottom, leftCamera, rightSide, rightBottom, rightCamera, leftHalf, rightHalf)
        }
    }

    /// Draws the root view collapsed with `leading` and `trailing` posted as a live activity, until
    /// two captures in a row are the same (the shape springs to the measured wings), and measures
    /// the ink. Writes `R22-render-<name>-T83.png` (the top of the canvas) when NOTCH_RENDER_DIR is set.
    func measure(_ name: String, notchHeight: CGFloat, leading: some View, trailing: some View) async throws -> Insets {
        let notch = CGSize(width: Self.notchWidth, height: notchHeight)
        let host = NotchHostModel()
        host.post(LiveActivity(id: "stand-in") { leading } trailing: { trailing }, from: "com.example.activity")
        let canvas = NotchLayout.canvasSize
        let image = try await settledCapture(NotchRootView(host: host, notchSize: notch, openSettings: {}), size: canvas)
        let scale = CGFloat(image.width) / canvas.width
        let top = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int((notchHeight + 12) * scale))))
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(NSBitmapImageRep(cgImage: top).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("R22-render-\(name)-T83.png"))
        }
        let insets = try #require(await Task.detached { Self.insets(top, scale: scale, notch: notch) }.value, "no ink in \(name)")
        print("R22 \(name) (notch \(notchHeight) pt): \(insets)")
        return insets
    }

    /// Draws `view` offscreen in a borderless window that is never shown, again until two captures in
    /// a row are the same (at most 2 s). It sleeps between captures instead of running the main run
    /// loop, so other suites' main-actor tests keep their deadlines meanwhile.
    func settledCapture(_ view: some View, size: CGSize) async throws -> CGImage {
        let hosting = NSHostingView(rootView: view.background(Self.backdrop).environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        var previous: Data?
        var rep: NSBitmapImageRep?
        for _ in 0..<40 {
            hosting.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let capture = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: capture)
            let data = capture.tiffRepresentation
            rep = capture
            if data != nil && data == previous { break }
            previous = data
        }
        return try #require(rep?.cgImage)
    }

    /// The shape's side edges on its middle row (found from outside, past the backdrop), its bottom
    /// on the centre column, and the outermost ink (red at least 14) of each wing.
    nonisolated static func insets(_ image: CGImage, scale: CGFloat, notch: CGSize) -> Insets? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func pixel(_ x: Int, _ y: Int) -> (red: Int, bright: Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(max(pixels[i], pixels[i + 1], pixels[i + 2])))
        }
        let center = width / 2
        let row = Int(notch.height * scale / 2)
        var left = 0, right = width - 1
        while left < center && pixel(left, row).bright > 60 { left += 1 }
        while right > center && pixel(right, row).bright > 60 { right -= 1 }
        var bottom = height - 1
        while bottom > 0 && pixel(center, bottom).bright > 60 { bottom -= 1 }
        let cameraHalf = Int((notch.width * scale / 2).rounded())
        var leftMinX = width, leftMaxX = -1, leftMaxY = -1, rightMinX = width, rightMaxX = -1, rightMaxY = -1
        for y in 0...bottom {
            for x in left...right where pixel(x, y).red >= 14 {
                if x < center {
                    leftMinX = min(leftMinX, x)
                    leftMaxX = max(leftMaxX, x)
                    leftMaxY = max(leftMaxY, y)
                } else {
                    rightMinX = min(rightMinX, x)
                    rightMaxX = max(rightMaxX, x)
                    rightMaxY = max(rightMaxY, y)
                }
            }
        }
        guard leftMaxX >= 0, rightMaxX >= 0 else { return nil }
        return Insets(
            leftSide: CGFloat(leftMinX - left) / scale,
            leftBottom: CGFloat(bottom - leftMaxY) / scale,
            leftCamera: CGFloat(center - cameraHalf - 1 - leftMaxX) / scale,
            rightSide: CGFloat(right - rightMaxX) / scale,
            rightBottom: CGFloat(bottom - rightMaxY) / scale,
            rightCamera: CGFloat(rightMinX - (center + cameraHalf)) / scale,
            leftHalf: CGFloat(center - left) / scale,
            rightHalf: CGFloat(right + 1 - center) / scale
        )
    }

    /// Side inset equal to bottom inset (±1 pt) on both wings, the camera at least as far, and the
    /// shape centred on the camera.
    func expectEven(_ insets: Insets, _ what: String) {
        #expect(abs(insets.leftSide - insets.leftBottom) <= 1, "\(what): \(insets)")
        #expect(abs(insets.rightSide - insets.rightBottom) <= 1, "\(what): \(insets)")
        #expect(insets.leftCamera >= insets.leftBottom - 1, "\(what): \(insets)")
        #expect(insets.rightCamera >= insets.rightBottom - 1, "\(what): \(insets)")
        #expect(abs(insets.leftHalf - insets.rightHalf) <= 1, "\(what): \(insets)")
    }

    /// NowPlaying's wings: the 22 pt album art and the 18 x 14 pt bars.
    @Test(arguments: [CGFloat(32), 37])
    func R22__now_playing_wings_keep_side_and_bottom_insets_equal(notchHeight: CGFloat) async throws {
        let insets = try await measure("nowplaying-\(Int(notchHeight))", notchHeight: notchHeight,
                                       leading: Color.white.frame(width: 22, height: 22),
                                       trailing: Color.white.frame(width: 18, height: 14))
        expectEven(insets, "now playing at \(notchHeight) pt")
    }

    /// Battery's wings: the charging symbol and the percentage, as rectangles of the size they lay
    /// out at in the wing's font.
    @Test(arguments: [CGFloat(32), 37])
    func R22__battery_wings_keep_side_and_bottom_insets_equal(notchHeight: CGFloat) async throws {
        let font = Font.system(size: 12, weight: .medium)
        let symbol = NSHostingView(rootView: Image(systemName: "battery.100percent.bolt").font(font)).fittingSize
        let percentage = NSHostingView(rootView: Text("100%").monospacedDigit().font(font)).fittingSize
        let insets = try await measure("battery-\(Int(notchHeight))", notchHeight: notchHeight,
                                       leading: Color.white.frame(width: symbol.width, height: symbol.height),
                                       trailing: Color.white.frame(width: percentage.width, height: percentage.height))
        expectEven(insets, "battery at \(notchHeight) pt")
    }

    /// Battery's real views, to look at: the symbol's and the text's ink sit inside their layout
    /// boxes, so only the render is kept and the insets printed.
    @Test func R22__battery_wings_render_as_drawn() async throws {
        let insets = try await measure("battery-real-32", notchHeight: 32,
                                       leading: Image(systemName: "battery.100percent.bolt").symbolRenderingMode(.hierarchical).foregroundStyle(.green),
                                       trailing: Text("100%").monospacedDigit())
        #expect(insets.leftSide > 0 && insets.rightSide > 0, "\(insets)")
    }
}
