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

/// The collapsed notch around the wings, as the app draws it: 78 pt wings beside the notch.
private struct CollapsedNotch: View {
    let model: NowPlayingModel

    var body: some View {
        HStack(spacing: 0) {
            NowPlayingWings.Leading(model: model)
                .frame(width: 78, height: 32)
            Spacer(minLength: 180)
            NowPlayingWings.Trailing(model: model)
                .frame(width: 78, height: 32)
        }
        .padding(.horizontal, 6)
        .frame(width: 348, height: 32)
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
