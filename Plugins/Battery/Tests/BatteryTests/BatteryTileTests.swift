import AppKit
import NotchKit
import SwiftUI
import Testing
@testable import Battery

@MainActor
private func plugin() throws -> BatteryPlugin {
    let id = BatteryPlugin.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("battery-tile-tests-\(UUID().uuidString)"),
        defaultsSuiteName: "battery-tile-tests.\(id)",
        keychainService: "battery-tile-tests.\(id)"
    )
    return BatteryPlugin(context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: SilentHost(), storage: storage), sampler: nil)
}

@MainActor
private final class SilentHost: NotchHost {
    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

/// The tile comes small (percentage and charging glyph) or wide (percentage, state and time left)
/// and has a definite size the app can place: the app's tiles are 90×90 (small) and 190×90 (wide).
@MainActor
@Test func R16__battery_tile_is_small_or_wide_with_a_definite_size() throws {
    let plugin = try plugin()
    let tile = try #require(plugin.tile)
    #expect(tile.supportedSizes == [.small, .wide])
    #expect(tile.defaultSize == .small)

    let readings: [PowerStatus?] = [
        PowerStatus(percentage: 79, isExternalPowerConnected: true, isCharging: true, isFullyCharged: false,
                    timeToEmpty: nil, timeToFull: .minutes(332)),
        PowerStatus(percentage: 100, isExternalPowerConnected: false, isCharging: false, isFullyCharged: false,
                    timeToEmpty: .calculating, timeToFull: nil),
        nil,
    ]
    for status in readings {
        plugin.update(status)
        let small = NSHostingView(rootView: tile.content(.small)).fittingSize
        let wide = NSHostingView(rootView: tile.content(.wide)).fittingSize
        for (size, limit) in [(small, CGSize(width: 90, height: 90)), (wide, CGSize(width: 190, height: 90))] {
            #expect(size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite, "\(size)")
            #expect(size.width <= limit.width && size.height <= limit.height, "\(size) does not fit \(limit) for \(String(describing: status))")
        }
    }
}

/// `view` drawn offscreen at its ideal size in a dark window, at the window's backing scale as the
/// app measures a tab: premultiplied RGBA rows from the top.
@MainActor
func renderedPixels(_ view: some View) throws -> (pixels: [UInt8], width: Int, height: Int, scale: CGFloat) {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    let size = hosting.fittingSize
    window.setContentSize(size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    return try withExtendedLifetime(window) { try renderedPixels(of: hosting) }
}

/// What `view` draws now, at its window's backing scale: premultiplied RGBA rows from the top.
@MainActor
func renderedPixels(of view: NSView) throws -> (pixels: [UInt8], width: Int, height: Int, scale: CGFloat) {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let image = try #require(rep.cgImage)
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (pixels, width, height, view.window?.backingScaleFactor ?? 1)
}

/// How far the outermost ink of `view` (any channel at least 14 over black, as the end-to-end
/// capture counts it) stays from its left, right and bottom edges, drawn offscreen at its ideal
/// size. The host adds the notch's margin around a tab, so a tab's own outer padding shows here.
@MainActor
func inkInsets(_ view: some View) throws -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
    let (pixels, width, height, scale) = try renderedPixels(view)
    var minX = width, maxX = -1, maxY = -1
    for y in 0..<height {
        for x in 0..<width {
            let i = (y * width + x) * 4
            if max(pixels[i], pixels[i + 1], pixels[i + 2]) >= 14 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }
    }
    try #require(maxX >= 0, "no ink in \(width)×\(height) px")
    return (CGFloat(minX) / scale, CGFloat(width - 1 - maxX) / scale, CGFloat(height - 1 - maxY) / scale)
}

/// Expects `insets` within R15's 2 pt tolerance: a line's descent or a glyph's side bearing stays
/// inside it, outer padding or a frame larger than the ink does not.
func expectNoOuterSpace(_ insets: (left: CGFloat, right: CGFloat, bottom: CGFloat), _ what: String) {
    print("R15 \(what): ink insets left \(insets.left) right \(insets.right) bottom \(insets.bottom) pt")
    for (side, inset) in [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)] {
        #expect(inset <= 2, "\(what): \(inset) pt of empty space at the \(side) edge")
    }
}


/// The tab is the size of what it draws, charging or not: the host adds the margin around it.
@MainActor
@Test func R15__battery_tab_draws_to_its_edges() throws {
    let plugin = try plugin()
    let tab = try #require(plugin.expandedTab)
    let readings: [(String, PowerStatus)] = [
        ("charging", PowerStatus(percentage: 79, isExternalPowerConnected: true, isCharging: true, isFullyCharged: false,
                                 timeToEmpty: nil, timeToFull: .minutes(332))),
        ("on battery", PowerStatus(percentage: 64, isExternalPowerConnected: false, isCharging: false, isFullyCharged: false,
                                   timeToEmpty: .minutes(185), timeToFull: nil)),
    ]
    for (name, status) in readings {
        plugin.update(status)
        // The battery symbol's outline starts at the tab's left edge: the view takes off the room
        // the symbol's image keeps left of it.
        expectNoOuterSpace(try inkInsets(tab.content), name)
    }
}
