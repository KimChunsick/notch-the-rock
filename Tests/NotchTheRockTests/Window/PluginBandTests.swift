import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// A plugin's screen opened from the home: ‹ and the plugin's name in the band left of the camera,
/// the plugin's settings gear right of it (none without a settings page), and the plugin's own view
/// right under the band with no back row above it. Drawn offscreen by the app's own root view.
@MainActor
@Suite struct PluginBandTests {
    /// About the size of the 13-inch MacBook Air's notch.
    nonisolated static let notch = CGSize(width: 185, height: 32)

    /// What the expanded notch draws, in points from the shape's top-left corner.
    struct Scan: CustomStringConvertible {
        /// Between the side walls, and from the top to the bottom edge.
        var shape: CGSize
        /// Ink in the band left and right of the camera, as x ranges; nil when the wing is blank.
        var leftInk: ClosedRange<CGFloat>?
        var rightInk: ClosedRange<CGFloat>?
        /// Ink pixels in the band over the camera and its clearance.
        var cameraInk: Int
        /// The ink below the band.
        var content: CGRect?

        var description: String {
            "shape \(shape), band left \(leftInk.map { "\($0)" } ?? "blank"), right \(rightInk.map { "\($0)" } ?? "blank"), "
                + "camera \(cameraInk) px, content \(content.map { "\($0)" } ?? "none")"
        }
    }

    /// The root view expanded on `plugin`'s screen, settled, scanned. Writes
    /// `R29-render-<name>-T94.png` when NOTCH_RENDER_DIR is set.
    func render(_ name: String, _ plugin: HomePlugin) async throws -> Scan {
        let fixture = HomeDefaults()
        defer { fixture.cleanUp() }
        let host = NotchHostModel(now: { .now }, pinnedExpansion: true, homeStore: fixture.store)
        host.plugins = [plugin]
        host.open(pluginID: plugin.pluginID)
        #expect(host.screen == .detail(pluginID: plugin.pluginID))
        let canvas = NotchLayout.canvasSize
        let image = try await NotchActivityRenderTests().settledCapture(NotchRootView(host: host, notchSize: Self.notch, openSettings: { _ in }), size: canvas)
        let scale = CGFloat(image.width) / canvas.width
        let scan = try #require(await Task.detached { Self.scan(image, scale: scale) }.value, "no shape in \(name)")
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let crop = CGRect(x: 0, y: 0, width: image.width, height: Int((scan.shape.height + 20) * scale))
            let top = try #require(image.cropping(to: crop))
            let data = try #require(NSBitmapImageRep(cgImage: top).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("R29-render-\(name)-T94.png"))
        }
        print("R29 \(name): \(scan)")
        return scan
    }

    /// The shape's side walls on a row just under the band and its bottom on the centre column (the
    /// shape is centred on the canvas, under the camera), then ink: red at least 40. Points count
    /// from the left wall, where the content's padding starts.
    nonisolated static func scan(_ image: CGImage, scale: CGFloat) -> Scan? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The backdrop and the shape's edge blending into it have no red; the white and grey ink does.
        func isInk(_ x: Int, _ y: Int) -> Bool {
            pixels[(y * width + x) * 4] >= 40
        }
        func isBlack(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return max(pixels[i], pixels[i + 1], pixels[i + 2]) <= 60
        }
        let px = { (points: CGFloat) in Int((points * scale).rounded()) }
        let center = width / 2
        let row = px(notch.height + 4)
        var left = center, right = center
        while left > 0 && isBlack(left - 1, row) { left -= 1 }
        while right < width - 1 && isBlack(right + 1, row) { right += 1 }
        var bottom = height - 1
        while bottom > 0 && !isBlack(center, bottom) { bottom -= 1 }
        guard right > left, bottom > row else { return nil }

        let camera = (px(CGFloat(center) / scale - notch.width / 2 - BandLayout.cameraClearance))...(px(CGFloat(center) / scale + notch.width / 2 + BandLayout.cameraClearance))
        var leftInk: ClosedRange<Int>?, rightInk: ClosedRange<Int>?
        var cameraInk = 0
        func extend(_ range: ClosedRange<Int>?, _ x: Int) -> ClosedRange<Int> {
            range.map { min($0.lowerBound, x)...max($0.upperBound, x) } ?? x...x
        }
        for y in 0..<px(notch.height) {
            for x in (left + 2)...(right - 2) where isInk(x, y) {
                if camera.contains(x) { cameraInk += 1 } else if x < center { leftInk = extend(leftInk, x) } else { rightInk = extend(rightInk, x) }
            }
        }
        var content: (x: ClosedRange<Int>, y: ClosedRange<Int>)?
        for y in px(notch.height)..<bottom {
            for x in (left + 2)...(right - 2) where isInk(x, y) {
                content = (extend(content?.x, x), extend(content?.y, y))
            }
        }
        let points = { (pixel: Int) in CGFloat(pixel - left) / scale }
        let range = { (pixels: ClosedRange<Int>?) in pixels.map { points($0.lowerBound)...points($0.upperBound + 1) } }
        return Scan(
            shape: CGSize(width: CGFloat(right + 1 - left) / scale, height: CGFloat(bottom + 1) / scale),
            leftInk: range(leftInk),
            rightInk: range(rightInk),
            cameraInk: cameraInk,
            content: content.map {
                CGRect(x: points($0.x.lowerBound), y: CGFloat($0.y.lowerBound) / scale,
                       width: CGFloat($0.x.count) / scale, height: CGFloat($0.y.count) / scale)
            }
        )
    }

    /// The camera housing over the shape, from the left wall.
    func camera(_ scan: Scan) -> ClosedRange<CGFloat> {
        let minX = (scan.shape.width - Self.notch.width) / 2
        return minX...(minX + Self.notch.width)
    }

    @Test func R29__a_plugin_screen_draws_back_and_its_name_left_of_the_camera_and_its_gear_right_of_it() async throws {
        let battery = HomePlugin(
            pluginID: "com.example.battery", name: "배터리", symbol: "battery.100percent",
            tab: PluginTab(title: "배터리", symbol: "battery.100percent") { BatteryStandIn() }, tile: nil, hasSettings: true
        )
        let scan = try await render("battery", battery)
        let camera = camera(scan)
        let back = try #require(scan.leftInk, "no back control left of the camera: \(scan)")
        #expect(back.upperBound <= camera.lowerBound - BandLayout.cameraClearance + 1, "back control reaches the camera: \(scan)")
        #expect(abs(back.lowerBound - NotchSizing.padding) <= 2, "back control not one padding in from the left wall: \(scan)")
        // ‹ and 배터리 in full: wider than the chevron alone.
        #expect(back.upperBound - back.lowerBound >= 40, "back control without the plugin's name: \(scan)")
        let gear = try #require(scan.rightInk, "no settings gear right of the camera: \(scan)")
        #expect(gear.lowerBound >= camera.upperBound + BandLayout.cameraClearance - 1, "gear reaches the camera: \(scan)")
        #expect(scan.cameraInk == 0, "ink over the camera: \(scan)")
        let content = try #require(scan.content, "no plugin view: \(scan)")
        #expect(abs(scan.shape.height - content.maxY - NotchSizing.padding) <= 2, "bottom padding: \(scan)")
    }

    @Test func R29__a_plugin_without_settings_has_no_gear_a_long_name_stays_clear_of_the_camera_and_no_back_row_tops_the_view() async throws {
        let name = "아주 긴 이름을 가진 플러그인의 화면이에요"
        let block = HomePlugin(
            pluginID: "com.example.block", name: name, symbol: "square",
            tab: PluginTab(title: name, symbol: "square") { Color.white.frame(width: 300, height: 60) }, tile: nil
        )
        let scan = try await render("nosettings", block)
        let camera = camera(scan)
        let back = try #require(scan.leftInk, "no back control left of the camera: \(scan)")
        #expect(back.upperBound <= camera.lowerBound - BandLayout.cameraClearance + 1, "long name reaches the camera: \(scan)")
        #expect(scan.rightInk == nil, "a gear without a settings page: \(scan)")
        #expect(scan.cameraInk == 0, "ink over the camera: \(scan)")
        #expect(scan.shape.width <= NotchSizing.maxWidth + 1, "the name widened the notch past its widest: \(scan)")
        // All ink under the band is the plugin's block, starting one padding under the band.
        let content = try #require(scan.content, "no plugin view: \(scan)")
        #expect(abs(content.minY - Self.notch.height - NotchSizing.padding) <= 1, "something above the plugin's view: \(scan)")
        #expect(abs(content.width - 300) <= 1 && abs(content.height - 60) <= 1, "ink besides the plugin's view: \(scan)")
        #expect(abs(scan.shape.height - content.maxY - NotchSizing.padding) <= 1, "bottom padding: \(scan)")
    }

    @Test func R29__the_gear_opens_that_plugins_settings_and_back_returns_home() throws {
        let fixture = HomeDefaults()
        defer { fixture.cleanUp() }
        let host = NotchHostModel(now: { .now }, homeStore: fixture.store)
        let withSettings = HomePlugin(pluginID: "com.example.clipboard", name: "클립보드", symbol: "doc", tab: PluginTab(title: "클립보드", symbol: "doc") { Text("") }, tile: nil, hasSettings: true)
        let without = HomePlugin(pluginID: "com.example.battery", name: "배터리", symbol: "battery.100percent", tab: PluginTab(title: "배터리", symbol: "battery.100percent") { Text("") }, tile: nil)
        host.plugins = [withSettings, without]
        var opened: [String?] = []
        host.open(pluginID: withSettings.pluginID)
        let band = PluginBand(host: host, plugin: withSettings, notchSize: Self.notch, width: NotchSizing.maxWidth, openSettings: { opened.append($0) })
        let gear = try #require(band.settingsAction)
        gear()
        #expect(opened == ["com.example.clipboard"])
        #expect(PluginBand(host: host, plugin: without, notchSize: Self.notch, width: NotchSizing.maxWidth, openSettings: { opened.append($0) }).settingsAction == nil)
        band.back()
        #expect(host.screen == .home)
        #expect(host.state == .expanded)
    }

    @Test func R29__settings_open_on_the_plugins_tab_at_that_plugins_page() throws {
        let selection = SettingsSelection()
        #expect(selection.tab == .general)
        selection.reveal(pluginID: "com.example.Clipboard")
        #expect(selection.tab == .plugins)
        let first = try #require(selection.revealed)
        let records = [URL(fileURLWithPath: "/tmp/a.notchplugin"), URL(fileURLWithPath: "/tmp/b.notchplugin")].enumerated().map { index, url in
            PluginRecord(bundleURL: url, source: .builtIn, identifier: index == 0 ? "com.example.battery" : "com.example.clipboard", name: "", version: "", fingerprint: nil, state: .on)
        }
        #expect(first.record(in: records) == records[1].id)
        // Asking again for the same plugin is a new request, so the page scrolls to it again.
        selection.reveal(pluginID: "com.example.Clipboard")
        #expect(selection.revealed != first)
    }
}
