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
    return BatteryPlugin(context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: SilentHost(), storage: storage))
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
