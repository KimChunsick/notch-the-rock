import AppKit
import NotchKit
import SwiftUI
import Testing
@testable import Clipboard

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

/// The plugin is never activated here, so it reads no pasteboard and no keychain item.
@MainActor
private func makePlugin() throws -> ClipboardPlugin {
    let id = ClipboardPlugin.manifest.id
    let storage = try PluginStorage(
        directory: try makeDirectory(),
        defaultsSuiteName: "clipboard-tile-tests.\(id)",
        keychainService: "clipboard-tile-tests.\(id)"
    )
    return ClipboardPlugin(context: NotchContext(pluginID: id, bundleURL: URL(fileURLWithPath: "/nonexistent"), host: SilentHost(), storage: storage))
}

/// The app's tile frames (`HomeGrid` in the app: 40 pt units 10 pt apart) and the largest content of
/// the expanded notch (`NotchSizing.maxContentSize`, the home grid's width).
private let tileFrames: [TileSize: CGSize] = [
    .small: CGSize(width: 90, height: 90),
    .wide: CGSize(width: 190, height: 90),
]
private let largestTab = CGSize(width: 390, height: 400)

private func expectDefinite(_ size: CGSize, within limit: CGSize, _ what: String) {
    #expect(size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite, "\(what): \(size)")
    #expect(size.width <= limit.width && size.height <= limit.height, "\(what): \(size) does not fit \(limit)")
}

extension MainActorTimingTests {
    /// The tile comes wide (the default) or small, and both sizes and the tab have a definite size that
    /// fits the app's frame for it, empty and with long entries of every kind.
    @MainActor
    @Test func R16__clipboard_tile_and_tab_fit_the_home_at_every_size() throws {
        let plugin = try makePlugin()
        let tile = try #require(plugin.tile)
        #expect(tile.supportedSizes == [.wide, .small])
        #expect(tile.defaultSize == .wide)
        for size in tile.supportedSizes {
            expectDefinite(NSHostingView(rootView: tile.content(size)).fittingSize, within: try #require(tileFrames[size]), "plugin \(size)")
        }
        expectDefinite(NSHostingView(rootView: try #require(plugin.expandedTab).content).fittingSize, within: largestTab, "plugin tab")

        let history = makeHistory(directory: try makeDirectory(), key: makeKey())
        history.record(try #require(ClipCapture(png: samplePNG())))
        history.record(.link("https://example.com/" + String(repeating: "long-path/", count: 30)))
        history.record(.text(String(repeating: "한 줄에 다 들어가지 않는 아주 긴 글이에요. ", count: 20)))
        for item in history.items {
            history.setPinned(true, for: item.id)
        }
        for size in tile.supportedSizes {
            expectDefinite(NSHostingView(rootView: ClipboardTile(history: history, size: size)).fittingSize, within: try #require(tileFrames[size]), "\(size)")
        }
        expectDefinite(NSHostingView(rootView: ClipboardView(history: history)).fittingSize, within: largestTab, "tab")
    }
}

/// The wide tile lists the three most recently copied entries, newest first and pinned ones
/// included; copying an older entry again brings it to the top. The small tile shows the newest.
@MainActor
@Test func R16__wide_clipboard_tile_lists_the_most_recent_entries_in_order() throws {
    let history = makeHistory(directory: try makeDirectory(), key: makeKey())
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    for (offset, text) in ["one", "two", "three", "four", "five"].enumerated() {
        history.record(.text(text), at: start + Double(offset))
    }
    let two = try #require(history.items.first { $0.text == "two" })
    history.setPinned(true, for: two.id)
    history.record(.text("two"), at: start + 10)

    let wide = ClipboardTile(history: history, size: .wide)
    #expect(wide.entries.map(\.text) == ["two", "five", "four"])
    #expect(wide.entries.map(\.isPinned) == [true, false, false])
    #expect(ClipboardTile(history: history, size: .small).entries.map(\.text) == ["two"])
}

extension MainActorTimingTests {
    /// The tile follows the tab's notice rule: it marks a history kept in memory only when the stored
    /// history cannot be read, or once entries have stayed unsaved for the notice delay, and still
    /// draws the entries of the session.
    @MainActor
    @Test func R16__clipboard_tile_warns_when_the_history_is_kept_in_memory_only() throws {
        let directory = try makeDirectory()
        let saved = makeHistory(directory: directory, key: makeKey())
        saved.record(.text("saved"))
        saved.flush()
        #expect(!ClipboardTile(history: saved, size: .wide).showsWarning(at: .now))

        let unreadable = makeHistory(directory: directory, key: makeKey())
        #expect(unreadable.isStoreUnreadable)
        unreadable.record(.text("captured while unreadable"))
        for size in [TileSize.wide, .small] {
            let tile = ClipboardTile(history: unreadable, size: size)
            #expect(tile.showsWarning(at: .now))
            #expect(tile.entries.map(\.text) == ["captured while unreadable"])
            expectDefinite(NSHostingView(rootView: tile).fittingSize, within: try #require(tileFrames[size]), "unreadable \(size)")
        }

        let clock = ManualClock()
        let memoryOnly = ClipboardHistory(logError: { _ in }, now: { clock.now })
        memoryOnly.open(nil)
        memoryOnly.record(.text("not saved"))
        let tile = ClipboardTile(history: memoryOnly, size: .wide)
        #expect(!tile.showsWarning(at: clock.now + ClipboardHistory.unsavedNoticeDelay - 0.1))
        #expect(tile.showsWarning(at: clock.now + ClipboardHistory.unsavedNoticeDelay))
    }
}

/// How far the outermost ink of `view` (any channel at least 14 over black, as the end-to-end
/// capture counts it) stays from its left, right and bottom edges, drawn offscreen at its ideal
/// size. The host adds the notch's margin around a tab, so a tab's own outer padding shows here.
@MainActor
private func inkInsets(_ view: some View) throws -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
    let (image, scale) = try renderOffscreen(view)
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = try #require(CGContext(
        data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
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
    try #require(maxX >= 0, "no ink in \(width)x\(height) px")
    return (CGFloat(minX) / scale, CGFloat(width - 1 - maxX) / scale, CGFloat(height - 1 - maxY) / scale)
}

/// Expects `insets` within R15's 2 pt tolerance: a line's descent or a glyph's side bearing stays
/// inside it, outer padding or a frame larger than the ink does not.
private func expectNoOuterSpace(_ insets: (left: CGFloat, right: CGFloat, bottom: CGFloat), _ what: String) {
    print("R15 \(what): ink insets left \(insets.left) right \(insets.right) bottom \(insets.bottom) pt")
    for (side, inset) in [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)] {
        #expect(inset <= 2, "\(what): \(inset) pt of empty space at the \(side) edge")
    }
}


extension MainActorTimingTests {
    /// The tab is the size of what it draws with no history, a short one and one longer than the list:
    /// the host adds the margin around it.
    @MainActor
    @Test func R15__clipboard_tab_draws_to_its_edges() throws {
        let empty = makeHistory(directory: try makeDirectory(), key: makeKey())
        let short = makeHistory(directory: try makeDirectory(), key: makeKey())
        short.record(.text("회의 메모"))
        short.record(.link("https://example.com"))
        let long = makeHistory(directory: try makeDirectory(), key: makeKey())
        for index in 1...12 {
            long.record(.text("기록 \(index)"))
        }
        for (name, history) in [("empty", empty), ("short", short), ("long", long)] {
            expectNoOuterSpace(try inkInsets(ClipboardView(history: history)), name)
        }
    }
}

extension MainActorTimingTests {
    /// Offered more width than its own, as the host does when the band beside the camera makes the
    /// notch wider than the screen, the search field and the card row run across it, so more cards show; at its own width it keeps today's size.
    @MainActor
    @Test func R15__clipboard_screen_fills_a_wider_offer() throws {
        let empty = makeHistory(directory: try makeDirectory(), key: makeKey())
        let long = makeHistory(directory: try makeDirectory(), key: makeKey())
        for index in 1...12 {
            long.record(.text("기록 \(index)"))
        }
        // Today's sizes. The cards keep their width, so the row may end a card spacing short of the
        // edge; the search field above it spans the offer.
        let cases: [(String, ClipboardView, CGSize)] = [
            ("empty", ClipboardView(history: empty), CGSize(width: 360, height: 45)),
            ("long", ClipboardView(history: long), CGSize(width: 360, height: 117)),
        ]
        for (name, view, today) in cases {
            let ideal = NSHostingView(rootView: view).fittingSize
            print("R15 clipboard \(name) ideal \(ideal)")
            #expect(abs(ideal.width - today.width) <= 0.5 && abs(ideal.height - today.height) <= 0.5, "\(name): the screen's own size changed: \(ideal)")
            let offered = ideal.width + 80
            let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
            #expect(abs(wide.height - ideal.height) <= 1, "\(name): wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
            let insets = try inkInsets(view.frame(width: offered))
            print("R15 clipboard \(name) offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
            #expect(insets.left <= 2 && insets.right <= 2, "\(name): the screen does not reach both edges of a \(offered) pt offer: \(insets)")
        }
    }
}
