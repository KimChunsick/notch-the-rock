import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// A volume or brightness HUD drawn offscreen by the app's root view: the collapsed notch widens
/// sideways only, the symbol sits in the left wing as far from the side edge as from the bottom,
/// and a thin rounded bar in the right wing is filled in proportion to the value. No title or
/// detail text is drawn and nothing hangs below the notch.
@MainActor
@Suite struct NotchHUDRenderTests {
    struct Drawn: CustomStringConvertible {
        /// The shape's bottom on the centre column, from the top of the canvas.
        var shapeHeight: CGFloat
        /// The shape's side edges from the camera's centre.
        var leftHalf: CGFloat
        var rightHalf: CGFloat
        /// The left wing's ink (the symbol): its width and its insets to the side edge and bottom.
        var symbolWidth: CGFloat
        var leftSide: CGFloat
        var leftBottom: CGFloat
        /// The right wing's ink (the bar's track): its size and its insets to the side edge and bottom.
        var trackLength: CGFloat
        var trackHeight: CGFloat
        var rightSide: CGFloat
        var rightBottom: CGFloat
        /// The filled part of the track on its middle row, from the track's left end.
        var fillLength: CGFloat
        /// The mean colour of the filled part, 0...255 per channel; zero without a fill.
        var fillRed: CGFloat
        var fillBlue: CGFloat
        /// Ink pixels below the notch or over the camera: there must be none.
        var stray: Int

        var fill: CGFloat { trackLength > 0 ? fillLength / trackLength : 0 }

        var description: String {
            String(format: "shape height %.1f, halves %.1f / %.1f; symbol %.1f wide, side %.1f bottom %.1f; bar %.1f x %.1f, side %.1f bottom %.1f; fill %.1f (%.3f), rgb red %.0f blue %.0f; stray %d",
                   shapeHeight, leftHalf, rightHalf, symbolWidth, leftSide, leftBottom, trackLength, trackHeight,
                   rightSide, rightBottom, fillLength, fill, fillRed, fillBlue, stray)
        }
    }

    static let cases: [(name: String, hud: HUD)] = [
        ("volume-25", HUD(symbol: "speaker.wave.1.fill", title: "볼륨", value: 0.25, detail: "25%")),
        ("volume-100", HUD(symbol: "speaker.wave.3.fill", title: "볼륨", value: 1, detail: "100%")),
        ("brightness-75", HUD(symbol: "sun.max.fill", title: "밝기", value: 0.75, detail: "75%")),
        ("muted", HUD(symbol: "speaker.slash.fill", title: "음소거", value: 0)),
    ]

    /// Draws the root view with `hud` shown until it settles and measures it. Writes
    /// `R25-render-<name>-T90.png` (the top of the canvas) when NOTCH_RENDER_DIR is set.
    func draw(_ name: String, _ hud: HUD, notchHeight: CGFloat) async throws -> Drawn {
        let notch = CGSize(width: NotchActivityRenderTests.notchWidth, height: notchHeight)
        let host = NotchHostModel()
        host.showHUD(hud, duration: .seconds(60), from: "com.example.hud")
        #expect(host.state == .hud)
        let canvas = NotchLayout.canvasSize
        let image = try await NotchActivityRenderTests().settledCapture(host: host, notchSize: notch)
        let scale = CGFloat(image.width) / canvas.width
        let top = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: image.width, height: Int((notchHeight + 40) * scale))))
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(NSBitmapImageRep(cgImage: top).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("R25-render-\(name)-T90.png"))
        }
        let drawn = try #require(await Task.detached { Self.measure(top, scale: scale, notch: notch) }.value, "no ink in \(name)")
        print("R25 \(name) (notch \(notchHeight) pt): \(drawn)")
        return drawn
    }

    /// The shape's edges (found from outside, past the blue backdrop), then the ink: any pixel whose
    /// red is at least 14 (the backdrop has none, the shape is black). The bar's fill is told from
    /// its dark track by a red of at least 120.
    nonisolated static func measure(_ image: CGImage, scale: CGFloat, notch: CGSize) -> Drawn? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        func rgb(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * width + x) * 4
            return (Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]))
        }
        func bright(_ x: Int, _ y: Int) -> Int { let p = rgb(x, y); return max(p.r, p.g, p.b) }
        let center = width / 2
        let row = Int(notch.height * scale / 2)
        var left = 0, right = width - 1
        while left < center && bright(left, row) > 60 { left += 1 }
        while right > center && bright(right, row) > 60 { right -= 1 }
        var bottom = 0
        while bottom + 1 < height && bright(center, bottom + 1) <= 60 { bottom += 1 }
        let notchBottom = Int((notch.height * scale).rounded())
        let cameraHalf = Int((notch.width * scale / 2).rounded())
        var leftBox = (minX: width, maxX: -1, minY: height, maxY: -1)
        var rightBox = leftBox
        var stray = 0
        for y in 0..<height {
            for x in 0..<width where rgb(x, y).r >= 14 {
                if y >= notchBottom || abs(x - center) < cameraHalf {
                    stray += 1
                } else if x < center {
                    leftBox = (min(leftBox.minX, x), max(leftBox.maxX, x), min(leftBox.minY, y), max(leftBox.maxY, y))
                } else {
                    rightBox = (min(rightBox.minX, x), max(rightBox.maxX, x), min(rightBox.minY, y), max(rightBox.maxY, y))
                }
            }
        }
        guard leftBox.maxX >= 0, rightBox.maxX >= 0 else { return nil }
        let barRow = (rightBox.minY + rightBox.maxY) / 2
        var fillMaxX = rightBox.minX - 1
        var red = 0, blue = 0, count = 0
        for x in rightBox.minX...rightBox.maxX where rgb(x, barRow).r >= 120 {
            fillMaxX = max(fillMaxX, x)
            red += rgb(x, barRow).r
            blue += rgb(x, barRow).b
            count += 1
        }
        return Drawn(
            shapeHeight: CGFloat(bottom + 1) / scale,
            leftHalf: CGFloat(center - left) / scale,
            rightHalf: CGFloat(right + 1 - center) / scale,
            symbolWidth: CGFloat(leftBox.maxX - leftBox.minX + 1) / scale,
            leftSide: CGFloat(leftBox.minX - left) / scale,
            leftBottom: CGFloat(bottom - leftBox.maxY) / scale,
            trackLength: CGFloat(rightBox.maxX - rightBox.minX + 1) / scale,
            trackHeight: CGFloat(rightBox.maxY - rightBox.minY + 1) / scale,
            rightSide: CGFloat(right - rightBox.maxX) / scale,
            rightBottom: CGFloat(bottom - rightBox.maxY) / scale,
            fillLength: CGFloat(fillMaxX - rightBox.minX + 1) / scale,
            fillRed: count > 0 ? CGFloat(red) / CGFloat(count) : 0,
            fillBlue: count > 0 ? CGFloat(blue) / CGFloat(count) : 0,
            stray: stray
        )
    }

    /// At the notch heights of the 13" and 15" MacBook Air: the symbol and the bar only in the side
    /// wings at the collapsed height, the bar 70–90 pt long and about 6 pt tall, filled in proportion
    /// to the value (±2 %), muted with an empty bar, brightness warm and volume cool.
    @Test(arguments: [CGFloat(32), 37])
    func R25__hud_draws_symbol_and_bar_in_the_collapsed_wings(notchHeight: CGFloat) async throws {
        for (name, hud) in Self.cases {
            let drawn = try await draw("\(name)-\(Int(notchHeight))", hud, notchHeight: notchHeight)
            let what = "\(name) at \(notchHeight) pt: \(drawn)"
            #expect(abs(drawn.shapeHeight - notchHeight) <= 0.5, "\(what)")
            #expect(drawn.stray == 0, "\(what)")
            #expect(abs(drawn.leftHalf - drawn.rightHalf) <= 1, "\(what)")
            // The symbol alone: no title beside it, as far from the side edge as from the bottom.
            #expect(drawn.symbolWidth <= 24, "\(what)")
            #expect(abs(drawn.leftSide - drawn.leftBottom) <= 1, "\(what)")
            // The bar alone: no detail text, thin, kept off the side edge as far as off the bottom.
            #expect((70...90).contains(drawn.trackLength), "\(what)")
            #expect(abs(drawn.trackHeight - 6) <= 1, "\(what)")
            #expect(abs(drawn.rightSide - drawn.rightBottom) <= 1, "\(what)")
            #expect(abs(drawn.fill - (hud.value ?? 0)) <= 0.02, "\(what)")
            if hud.symbol.hasPrefix("sun.") {
                #expect(drawn.fillRed - drawn.fillBlue >= 40, "warm fill: \(what)")
            } else if drawn.fillLength > 0 {
                #expect(drawn.fillBlue >= drawn.fillRed - 4, "cool fill: \(what)")
            }
        }
    }
}
