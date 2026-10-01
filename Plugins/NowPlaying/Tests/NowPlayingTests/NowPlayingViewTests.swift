import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NowPlaying

/// The app's tile frames (`HomeGrid`: 40 pt units 10 pt apart) and the largest content of the
/// expanded notch (the home grid's width).
private let tileFrames: [TileSize: CGSize] = [
    .small: CGSize(width: 90, height: 90),
    .wide: CGSize(width: 190, height: 90),
]
private let largestTab = CGSize(width: 390, height: 400)

private func expectDefinite(_ size: CGSize, within limit: CGSize, _ what: String) {
    #expect(size.width > 0 && size.height > 0 && size.width.isFinite && size.height.isFinite, "\(what): \(size)")
    #expect(size.width <= limit.width && size.height <= limit.height, "\(what): \(size) does not fit \(limit)")
}

/// Models in every state the views draw: nothing, unavailable, playing with a long title and a
/// cover, paused without one.
@MainActor
private func models() throws -> [(String, NowPlayingModel)] {
    let nothing = NowPlayingModel()
    let unavailable = NowPlayingModel()
    unavailable.apply(.unavailable(reason: "test"))
    let playing = NowPlayingModel()
    playing.apply(try #require(HelperLine(infoLine(
        title: String(repeating: "아주 긴 곡 제목이에요 ", count: 6),
        artist: String(repeating: "Artist ", count: 10),
        artwork: artworkObject(samplePNG())
    ))))
    let paused = NowPlayingModel()
    paused.apply(try #require(HelperLine(infoLine(artist: nil, album: nil, duration: nil, rate: 0, playing: false))))
    return [("nothing", nothing), ("unavailable", unavailable), ("playing", playing), ("paused", paused)]
}

/// The tile starts wide and can be small; both sizes and the tab have a definite size that fits
/// the app's frame for it in every state.
@MainActor
@Test func R08__tile_is_wide_then_small_and_fits_the_home() throws {
    let plugin = NowPlayingPlugin(context: try makeContext(host: RecordingHost()), launcher: FakeLauncher(), clock: VirtualClock())
    let tile = try #require(plugin.tile)
    #expect(tile.supportedSizes == [.wide, .small])
    #expect(tile.defaultSize == .wide)
    for size in tile.supportedSizes {
        expectDefinite(NSHostingView(rootView: tile.content(size)).fittingSize, within: try #require(tileFrames[size]), "plugin \(size)")
    }
    expectDefinite(NSHostingView(rootView: try #require(plugin.expandedTab).content).fittingSize, within: largestTab, "plugin tab")

    for (name, model) in try models() {
        for size in tile.supportedSizes {
            let view = NowPlayingTile(model: model, size: size) { _ in }
            expectDefinite(NSHostingView(rootView: view).fittingSize, within: try #require(tileFrames[size]), "\(name) \(size)")
        }
        expectDefinite(NSHostingView(rootView: NowPlayingView(model: model) { _ in }).fittingSize, within: largestTab, "\(name) tab")
    }
}

/// The bars move while playing and stand still in one pattern while paused.
@MainActor
@Test func R08__bars_move_only_while_playing() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let frames = (0..<10).map { start + Double($0) * 0.1 }
    let playing = frames.map { PlaybackBars.levels(at: $0, isPlaying: true) }
    #expect(Set(playing.map { $0.map { ($0 * 1000).rounded() } }).count == frames.count)
    #expect(playing.allSatisfy { $0.count == 4 && $0.allSatisfy { (0.2...1).contains($0) } })
    let paused = frames.map { PlaybackBars.levels(at: $0, isPlaying: false) }
    #expect(paused.allSatisfy { $0 == PlaybackBars.stillLevels })
}

/// The collapsed notch around the wings, as the app draws it at a 32 pt notch: each view as far
/// from the side edge as from the bottom (5 pt beside the art, 9 pt beside the bars), both wings
/// as wide as the bars' (36 pt).
private struct CollapsedNotch: View {
    let model: NowPlayingModel

    var body: some View {
        HStack(spacing: 0) {
            NowPlayingWings.Leading(model: model)
                .padding(5)
                .frame(width: 36, alignment: .leading)
            Spacer(minLength: 185)
            NowPlayingWings.Trailing(model: model)
                .padding(9)
                .frame(width: 36, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .frame(width: 185 + 2 * (6 + 36), height: 32)
        .background(.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
        .foregroundStyle(.white)
    }
}

/// A view on the expanded notch's black, in a tile's frame when `tile` is set.
private struct OnNotch<Content: View>: View {
    var tile: CGSize?
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if let tile {
                content
                    .frame(width: tile.width, height: tile.height)
                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            } else {
                content
            }
        }
        .padding(12)
        .background(.black)
    }
}

@MainActor
private func render(_ view: some View) throws -> CGImage {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = 2
    return try #require(renderer.cgImage)
}

/// Renders the wings playing and paused, the tab and both tiles. With NOWPLAYING_RENDER_DIR set the
/// images are saved there as R08-render-*.png.
@MainActor
@Test func R08__renders_wings_tab_and_tiles() throws {
    let playing = NowPlayingModel()
    playing.apply(try #require(HelperLine(infoLine(
        title: "Blue in Green", artist: "Miles Davis", duration: 337, elapsed: 121,
        timestamp: Date.now.timeIntervalSince1970, artwork: artworkObject(samplePNG(side: 240))
    ))))
    let paused = NowPlayingModel()
    paused.apply(try #require(HelperLine(infoLine(
        title: "Blue in Green", artist: "Miles Davis", duration: 337, elapsed: 121,
        timestamp: Date.now.timeIntervalSince1970, rate: 0, playing: false, artwork: artworkObject(samplePNG(side: 240))
    ))))
    let renders: [(String, CGImage)] = [
        ("wings-playing", try render(CollapsedNotch(model: playing).padding(12).background(.gray))),
        ("wings-paused", try render(CollapsedNotch(model: paused).padding(12).background(.gray))),
        ("tab", try render(OnNotch { NowPlayingView(model: playing) { _ in } })),
        ("tile-wide", try render(OnNotch(tile: tileFrames[.wide]) { NowPlayingTile(model: playing, size: .wide) { _ in } })),
        ("tile-small", try render(OnNotch(tile: tileFrames[.small]) { NowPlayingTile(model: playing, size: .small) { _ in } })),
    ]
    let directory = ProcessInfo.processInfo.environment["NOWPLAYING_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    for (name, image) in renders {
        #expect(image.width > 100 && image.height > 50, "\(name)")
        guard let directory else { continue }
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("R08-render-\(name).png"))
    }
}

/// How far the outermost ink of `view` (any channel at least 14 over black, as the end-to-end
/// capture counts it) stays from its left, right and bottom edges, drawn offscreen at its ideal
/// size. The host adds the notch's margin around a tab, so a tab's own outer padding shows here.
@MainActor
private func inkInsets(_ view: some View) throws -> (left: CGFloat, right: CGFloat, bottom: CGFloat) {
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
    let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = hosting
    // Measured in the window, at its backing scale, as the app measures a tab.
    let size = hosting.fittingSize
    window.setContentSize(size)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let image = try #require(rep.cgImage)
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
    try #require(maxX >= 0, "no ink in \(size)")
    let scale = window.backingScaleFactor
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


/// The tab is the size of what it draws in every state: the host adds the margin around it.
@MainActor
@Test func R15__now_playing_tab_draws_to_its_edges() throws {
    for (name, model) in try models() {
        expectNoOuterSpace(try inkInsets(NowPlayingView(model: model) { _ in }), name)
    }
}

/// The wings' views carry no space of their own: the host puts the same space beside and below
/// each one (R22), so their ink reaches their left, right and bottom edges within 1 pt. The art
/// fills its square; the bars stand on its bottom edge, playing or paused.
@MainActor
@Test func R22__wing_views_have_no_outer_padding() throws {
    for (name, model) in try models() where name == "playing" || name == "paused" {
        let views: [(String, AnyView)] = [
            ("leading", AnyView(NowPlayingWings.Leading(model: model))),
            ("trailing", AnyView(NowPlayingWings.Trailing(model: model))),
        ]
        for (side, view) in views {
            let insets = try inkInsets(view)
            print("R22 \(name) \(side): ink insets left \(insets.left) right \(insets.right) bottom \(insets.bottom) pt")
            for (edge, inset) in [("left", insets.left), ("right", insets.right), ("bottom", insets.bottom)] {
                #expect(inset <= 1, "\(name) \(side): \(inset) pt of empty space at the \(edge) edge")
            }
        }
    }
}

/// The wide tile has previous, play/pause and next, the small one play/pause alone. Each sends the
/// command the tab's button sends through the plugin's helper, and each is a hit target of at least
/// 24 x 24 pt.
@MainActor
@Test func R24__tile_buttons_send_previous_play_pause_and_next() throws {
    let launcher = FakeLauncher()
    let plugin = NowPlayingPlugin(context: try makeContext(host: RecordingHost()), launcher: launcher, clock: VirtualClock())
    let playing = TrackInfo(title: "t", sampledAt: Date(timeIntervalSince1970: 0), isPlaying: true)
    let paused = TrackInfo(title: "t", sampledAt: Date(timeIntervalSince1970: 0), isPlaying: false)

    let wide = NowPlayingTile.buttons(for: playing, size: .wide, send: plugin.send)
    #expect(wide.map(\.label) == ["이전 곡", "일시정지", "다음 곡"])
    wide.forEach { $0.action() }
    #expect(launcher.sent == [.previous, .pause, .next])

    let small = NowPlayingTile.buttons(for: paused, size: .small, send: plugin.send)
    #expect(small.map(\.label) == ["재생"])
    small.forEach { $0.action() }
    #expect(launcher.sent == [.previous, .pause, .next, .play])

    for button in wide + small {
        let size = NSHostingView(rootView: button).fittingSize
        #expect(size.width >= 24 && size.height >= 24, "\(button.label): \(size)")
    }
}

/// Both tile sizes while a track plays, to look at: with NOWPLAYING_RENDER_DIR set they are saved
/// there as R24-render-tile-*-T83.png.
@MainActor
@Test func R24__renders_both_tiles_with_their_buttons() throws {
    let playing = NowPlayingModel()
    playing.apply(try #require(HelperLine(infoLine(
        title: "알루미늄", artist: "Broken Valentine", duration: 343, elapsed: 120,
        timestamp: Date.now.timeIntervalSince1970, artwork: artworkObject(samplePNG(side: 240))
    ))))
    let directory = ProcessInfo.processInfo.environment["NOWPLAYING_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
    for size in [TileSize.wide, .small] {
        let image = try render(OnNotch(tile: tileFrames[size]) { NowPlayingTile(model: playing, size: size) { _ in } })
        #expect(image.width > 100)
        guard let directory else { continue }
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("R24-render-tile-\(size == .wide ? "wide" : "small")-T83.png"))
    }
}

/// Offered more width than its own, as the host does when the band beside the camera makes the
/// notch wider than the screen, a playing track's column spreads to the offer's right edge next to
/// the art without wrapping; at its own width the screen keeps today's size.
@MainActor
@Test func R15__now_playing_screen_fills_a_wider_offer() throws {
    let models = Dictionary(uniqueKeysWithValues: try models())
    let view = NowPlayingView(model: try #require(models["playing"])) { _ in }
    let ideal = NSHostingView(rootView: view).fittingSize
    print("R15 now playing ideal \(ideal)")
    // Today's size.
    #expect(abs(ideal.width - 332) <= 0.5 && abs(ideal.height - 88) <= 0.5, "the screen's own size changed: \(ideal)")
    let offered = ideal.width + 80
    let wide = NSHostingView(rootView: view.frame(width: offered)).fittingSize
    #expect(abs(wide.height - ideal.height) <= 1, "wrapped or cut at \(offered) pt: \(wide) vs \(ideal)")
    let insets = try inkInsets(view.frame(width: offered))
    print("R15 now playing offered \(offered) pt: ink insets left \(insets.left) right \(insets.right)")
    #expect(insets.left <= 2 && insets.right <= 2, "the screen does not reach both edges of a \(offered) pt offer: \(insets)")
}
