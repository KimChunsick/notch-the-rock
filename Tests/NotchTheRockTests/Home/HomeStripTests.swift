import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Tiles start on a small tile's column (R34), every plugin can be a tile (R35), and the plugins off
/// the grid line up as round icons in a strip under it (R36).
@MainActor
struct HomeStripTests {
    let fixture = HomeDefaults()

    func origin(_ column: Int, _ row: Int) -> GridOrigin { GridOrigin(column: column, row: row) }

    func host(_ plugins: [HomePlugin]) -> NotchHostModel {
        let host = NotchHostModel(now: { .now }, homeStore: fixture.store)
        host.plugins = plugins
        return host
    }

    // MARK: R34 — cell columns

    @Test func R34__a_drop_anywhere_lands_on_a_small_tiles_column() {
        defer { fixture.cleanUp() }
        for size in TileSize.allCases {
            for x in stride(from: CGFloat(-60), through: 460, by: 5) {
                let column = HomeGrid.origin(nearest: CGPoint(x: x, y: 0), for: size).column
                #expect(column % TileSize.small.columns == 0, "\(size) dropped at x \(x) starts at column \(column)")
                #expect(HomeLayout.isInside(size, at: origin(column, 0)))
            }
        }
        // Half a cell over goes to the nearer cell, never in between.
        #expect(HomeGrid.origin(nearest: CGPoint(x: 49, y: 0), for: .small).column == 0)
        #expect(HomeGrid.origin(nearest: CGPoint(x: 51, y: 0), for: .small).column == 2)
        #expect(HomeGrid.origin(nearest: CGPoint(x: 150, y: 0), for: .small).column == 4)
    }

    @Test func R34__move_add_and_resize_keep_every_tile_on_a_cell_column() {
        defer { fixture.cleanUp() }
        var layout = HomeLayout.empty.reconciled(with: [homePlugin("a", sizes: [.small, .wide, .large]), homePlugin("b")])
        #expect(layout.tile(for: "b")?.origin == origin(2, 0))
        // Half a cell over is refused like a place off a row; the tile stays.
        for column in [1, 3, 5] {
            #expect(!layout.fits(.small, at: origin(column, 2)))
            let moved = layout.move("b", to: origin(column, 2))
            #expect(!moved)
        }
        #expect(layout.tile(for: "b")?.origin == origin(2, 0))
        let moved = layout.move("b", to: origin(6, 2))
        #expect(moved)
        // The first free place for a new tile is a cell column.
        layout.remove("a")
        let added = layout.add("c", size: .small)
        #expect(added)
        #expect(layout.tile(for: "c")?.origin == origin(0, 0))
        let readded = layout.add("a", size: .small)
        #expect(readded)
        #expect(layout.tile(for: "a")?.origin == origin(2, 0))
        let resized = layout.resize("a", to: .wide)
        #expect(resized)
        let resizedLarge = layout.resize("c", to: .large)
        #expect(!resizedLarge)
        for tile in layout.tiles {
            #expect(tile.origin.column % TileSize.small.columns == 0, "\(tile)")
        }
    }

    /// A layout saved before R34 with tiles half a cell over: each moves to the nearest free cell
    /// column of its row (the left one on a tie), after the tiles already on cells, which keep their
    /// places; one with no free cell left goes to the strip.
    @Test func R34__a_layout_stored_half_a_cell_over_moves_to_the_nearest_free_cells() throws {
        defer { fixture.cleanUp() }
        let json = """
        {"known":["a","b","c","d","e","f","g"],"tiles":[\
        {"plugin":"b","size":"small","column":3,"row":0},\
        {"plugin":"a","size":"small","column":0,"row":0},\
        {"plugin":"c","size":"small","column":6,"row":0},\
        {"plugin":"d","size":"wide","column":0,"row":2},\
        {"plugin":"e","size":"small","column":5,"row":2},\
        {"plugin":"f","size":"small","column":1,"row":0},\
        {"plugin":"g","size":"small","column":1,"row":2}]}
        """
        fixture.defaults.set(Data(json.utf8), forKey: HomeLayoutStore.key)
        let home = HomeModel(store: fixture.store)
        home.plugins = ["a", "b", "c", "d", "e", "f", "g"].map { homePlugin($0, sizes: $0 == "d" ? [.wide] : [.small]) }
        let placed = Dictionary(uniqueKeysWithValues: home.tiles.map { ($0.plugin.pluginID, $0.placement.origin) })
        #expect(placed == [
            "a": origin(0, 0),
            "b": origin(2, 0),
            "c": origin(6, 0),
            "d": origin(0, 2),
            "e": origin(4, 2),
            "f": origin(4, 0),
            "g": origin(6, 2),
        ])
        // A tile needs a free cell: with the grid full a later one goes to the strip.
        let full = """
        {"known":["a","b","c","d","x"],"tiles":[\
        {"plugin":"a","size":"small","column":0,"row":0},\
        {"plugin":"b","size":"small","column":2,"row":0},\
        {"plugin":"c","size":"small","column":4,"row":0},\
        {"plugin":"d","size":"small","column":6,"row":0},\
        {"plugin":"x","size":"small","column":3,"row":0}]}
        """
        fixture.defaults.set(Data(full.utf8), forKey: HomeLayoutStore.key)
        let second = HomeModel(store: fixture.store)
        second.plugins = ["a", "b", "c", "d", "x"].map { homePlugin($0) }
        #expect(second.tiles.map(\.placement.origin.column) == [0, 2, 4, 6])
        #expect(second.list.map(\.pluginID) == ["x"])
    }

    // MARK: R35 — default tiles

    @Test func R35__a_plugin_without_a_tile_goes_on_the_grid_as_a_small_default_tile() {
        defer { fixture.cleanUp() }
        let host = host([
            homePlugin("battery", sizes: [.small], name: "배터리"),
            homePlugin("agents", sizes: [], name: "코딩 에이전트"),
            homePlugin("hello", sizes: [], tab: false, name: "인사"),
        ])
        let home = host.home
        // Only a plugin's own tile takes a place by itself; the others wait in the strip.
        #expect(home.tiles.map(\.plugin.pluginID) == ["battery"])
        #expect(home.list.map(\.pluginID) == ["agents", "hello"])
        home.beginEditing()
        #expect(home.canAdd("agents"))
        host.tapHomePlugin("agents")
        #expect(home.layout.tile(for: "agents") == TilePlacement(pluginID: "agents", size: .small, origin: origin(2, 0)))
        // Small only.
        #expect(!home.canResize("agents", to: .wide))
        #expect(!home.resize("agents", to: .wide))
        #expect(home.move("agents", to: origin(4, 2)))
        home.remove("agents")
        #expect(home.layout.tile(for: "agents") == nil)
        #expect(home.list.map(\.pluginID) == ["agents", "hello"])
        #expect(home.add("agents"))
        #expect(home.add("hello"))
        home.finishEditing()
        #expect(home.entries.map(\.kind) == [.tile(.small), .tile(.small), .tile(.small)])

        // A tap on the default tile opens the plugin's screen, the host's fallback screen for a plugin
        // without one of its own; Esc returns home from both.
        host.setHovering(true)
        host.tapHomePlugin("agents")
        #expect(host.screen == .detail(pluginID: "agents"))
        host.back()
        host.tapHomePlugin("hello")
        #expect(host.screen == .detail(pluginID: "hello"))
        host.escape()
        #expect(host.screen == .home)

        // The default tile is kept like any other.
        let relaunched = HomeModel(store: fixture.store)
        relaunched.plugins = home.plugins
        #expect(relaunched.layout == home.layout)
    }

    @Test func R35__the_default_tile_shows_the_plugins_symbol_over_its_name() throws {
        defer { fixture.cleanUp() }
        let host = host([homePlugin("agents", sizes: [], name: "코딩 에이전트")])
        _ = host.home.add("agents")
        let image = try render(HomeView(host: host), name: "R35-render-default-tile-T116.png")
        let frame = HomeGrid.frame(of: try #require(host.home.layout.tile(for: "agents")))
        // Rows of white ink inside the tile: the symbol, a gap, then the name.
        let inked = (Int(frame.minY) + 4..<Int(frame.maxY) - 4).filter { y in
            (Int(frame.minX) + 4..<Int(frame.maxX) - 4).contains { image.brightness($0, y) > 150 }
        }
        let bands = zip(inked, inked.dropFirst()).filter { $1 - $0 > 1 }.count + (inked.isEmpty ? 0 : 1)
        #expect(bands >= 2, "ink rows \(inked)")
        // The default tile has the tiles' fill.
        #expect((20...40).contains(image.brightness(Int(frame.minX) + 6, Int(frame.midY))))
    }

    @Test func R35__the_fallback_screens_button_opens_the_plugins_settings() throws {
        defer { fixture.cleanUp() }
        var opened: [String?] = []
        let hello = HomePlugin(pluginID: "hello", name: "인사", symbol: "hand.wave", tab: nil, tile: nil, hasSettings: true)
        let action = try #require(DefaultScreen(plugin: hello, openSettings: { opened.append($0) }).settingsAction)
        action()
        #expect(opened == ["hello"])
        #expect(DefaultScreen(plugin: Self.symbolPlugins[1], openSettings: { opened.append($0) }).settingsAction == nil)
    }

    // MARK: R36 — the strip

    @Test func R36__plugins_off_the_grid_are_round_icons_in_one_row_without_names() throws {
        defer { fixture.cleanUp() }
        let names = ["코딩 에이전트", "아주 긴 이름의 플러그인", "인사"]
        let host = host(names.enumerated().map { homePlugin("p\($0.offset)", sizes: [], name: $0.element) })
        let image = try render(HomeView(host: host), name: "R36-render-strip-T116.png")
        let icon = HomeGrid.stripIcon
        #expect(image.size.height == icon)
        #expect(image.size.width == HomeGrid.size.width)
        for index in names.indices {
            let left = CGFloat(index) * (icon + HomeGrid.gap)
            // Filled in the middle, dark in the corners: a circle.
            #expect(image.brightness(Int(left + 4), Int(icon / 2)) > 20)
            for (x, y) in [(left + 1, 1.0), (left + icon - 2, 1.0), (left + 1, icon - 2), (left + icon - 2, icon - 2)] {
                #expect(image.brightness(Int(x), Int(y)) < 12, "icon \(index) corner \(x), \(y)")
            }
        }
        // No name beside or under the icons: nothing is drawn after the last one.
        let end = CGFloat(names.count) * (icon + HomeGrid.gap)
        for x in Int(end)..<Int(image.size.width) {
            for y in 0..<Int(icon) {
                #expect(image.brightness(x, y) < 12, "ink at \(x), \(y)")
                if image.brightness(x, y) >= 12 { return }
            }
        }
    }

    @Test func R36__the_strip_scrolls_sideways_when_its_icons_outgrow_the_grid() throws {
        defer { fixture.cleanUp() }
        let host = host([homePlugin("tile", sizes: [.wide])] + (1...12).map { homePlugin("s\($0)", sizes: [], name: "플러그인 \($0)") })
        let hosting = NSHostingView(rootView: HomeView(host: host))
        #expect(hosting.fittingSize.width == HomeGrid.size.width)
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        settle(hosting)
        let strip = try #require(scrollViews(in: hosting).first)
        let document = try #require(strip.documentView)
        #expect(strip.frame.width <= HomeGrid.size.width + 0.5)
        #expect(document.frame.width >= 12 * HomeGrid.stripIcon + 11 * HomeGrid.gap - 0.5)
        #expect(document.frame.width > strip.contentView.bounds.width + 100)
        // One row.
        #expect(strip.frame.height <= HomeGrid.stripIcon + 0.5)
    }

    /// The icon under the pointer or the keyboard's focus shows its name in a light bubble above it,
    /// drawn over what lies above the strip rather than clipped by it; a longer name makes a wider
    /// bubble, and the bubble goes when the pointer leaves.
    @Test func R36__hovering_or_focusing_an_icon_shows_its_name_in_a_bubble() throws {
        defer { fixture.cleanUp() }
        let host = host(Self.symbolPlugins)
        #expect(try bubble(host, "R36-render-no-bubble-T121.png") == nil)

        host.toggleFromKeyboard()
        #expect(host.keyboard.focus == "agents")
        let long = try #require(try bubble(host, "R36-render-focus-bubble-T121.png"))
        expectBubble(long, over: 0)
        _ = host.handleKey(.right)
        let short = try #require(try bubble(host, "R36-render-focus-bubble-2-T121.png"))
        expectBubble(short, over: 1)
        #expect(short.width < long.width - 10, "인사 \(short), 코딩 에이전트 \(long)")

        // The pointer on the third icon wins over the focus on the second, and leaving removes it.
        host.home.setHovering(true, icon: "notes")
        let hovered = try #require(try bubble(host, "R36-render-hover-bubble-T121.png"))
        expectBubble(hovered, over: 2)
        #expect(hovered.minX > HomeGrid.stripIcon * 1.5 + HomeGrid.gap, "a second bubble beside \(hovered)")
        host.home.setHovering(true, icon: "hello")
        host.home.setHovering(false, icon: "notes")
        #expect(host.home.hoveredIcon == "hello")
        host.home.setHovering(false, icon: "hello")
        host.keyboard.reset()
        #expect(try bubble(host, "R36-render-hover-left-T121.png") == nil)
    }

    /// A name wider than the strip keeps its bubble inside the strip, as wide as the strip at most,
    /// and ends in an ellipsis: the name's ink stops short of the bubble's right edge.
    @Test func R36__a_name_wider_than_the_strip_is_cut_short_inside_it() throws {
        defer { fixture.cleanUp() }
        let name = String(repeating: "가나다라마바사아자차", count: 6)
        let long = HomePlugin(pluginID: "a-long", name: name, symbol: "puzzlepiece", tab: nil, tile: nil)
        let host = host([long] + Self.symbolPlugins)
        host.home.setHovering(true, icon: "a-long")
        let (box, inkEnd) = try #require(try bubbleInk(host, "R36-render-long-bubble-T124.png"))
        expectBubble(box, over: 0)
        #expect(box.width >= HomeGrid.size.width - 2, "bubble \(box) narrower than the strip")
        #expect(CGFloat(inkEnd) < box.maxX - 4, "the name's ink runs to \(inkEnd), into the bubble's edge \(box)")
    }

    @Test func R36__a_tap_opens_the_screen_and_in_edit_mode_puts_the_plugin_on_the_grid() {
        defer { fixture.cleanUp() }
        let host = host(
            (0..<7).map { homePlugin("t\($0)") }
                + [homePlugin("wide", sizes: [.wide, .small]), homePlugin("agents", sizes: [], name: "코딩 에이전트")]
                + [homePlugin("hello", sizes: [], tab: false, name: "인사")]
        )
        let home = host.home
        #expect(home.list.map(\.pluginID) == ["wide", "agents", "hello"])
        host.setHovering(true)
        host.tapHomePlugin("agents")
        #expect(host.screen == .detail(pluginID: "agents"))
        host.back()
        host.tapHomePlugin("hello")
        #expect(host.screen == .detail(pluginID: "hello"))
        host.back()

        home.beginEditing()
        // The first free cell at the plugin's default size: no wide place is free, a small one is.
        host.tapHomePlugin("wide")
        #expect(home.layout.tile(for: "wide") == nil)
        #expect(home.notice == "빈 칸이 없어서 위젯으로 올릴 수 없어요")
        host.tapHomePlugin("agents")
        #expect(home.notice == nil)
        #expect(home.layout.tile(for: "agents") == TilePlacement(pluginID: "agents", size: .small, origin: origin(6, 2)))
        #expect(host.screen == .home)
        // A full grid: a short notice, nothing moves.
        let before = home.layout
        host.tapHomePlugin("wide")
        #expect(home.layout == before)
        #expect(home.notice == "빈 칸이 없어서 위젯으로 올릴 수 없어요")
        home.finishEditing()
        #expect(home.notice == nil)
    }

    @Test func R36__arrow_keys_move_along_the_strip_and_return_opens() {
        defer { fixture.cleanUp() }
        let host = host([homePlugin("A", sizes: [.wide])] + (1...10).map { homePlugin("S\($0)", sizes: [], name: "줄 \($0)") })
        host.toggleFromKeyboard()
        #expect(host.keyboard.focus == "A")
        #expect(host.handleKey(.down))
        #expect(host.keyboard.focus == "S1")
        #expect(host.listScrollTarget == "S1")
        for _ in 0..<9 { _ = host.handleKey(.right) }
        #expect(host.keyboard.focus == "S10")
        #expect(host.listScrollTarget == "S10")
        _ = host.handleKey(.right)
        #expect(host.keyboard.focus == "S10")
        _ = host.handleKey(.down)
        #expect(host.keyboard.focus == "S10")
        _ = host.handleKey(.left)
        #expect(host.keyboard.focus == "S9")
        #expect(host.handleKey(.enter))
        #expect(host.screen == .detail(pluginID: "S9"))
        _ = host.handleKey(.escape)
        _ = host.handleKey(.up)
        #expect(host.keyboard.focus == "A")
    }

    /// Edit mode with a layout stored half a cell over, a default tile and the strip with its + badges.
    @Test func R34__in_the_edit_render_every_tile_starts_on_a_cell_edge() throws {
        defer { fixture.cleanUp() }
        let json = """
        {"known":["battery","clipboard","cpu"],"tiles":[\
        {"plugin":"battery","size":"small","column":0,"row":0},\
        {"plugin":"clipboard","size":"small","column":3,"row":0},\
        {"plugin":"cpu","size":"small","column":6,"row":0}]}
        """
        fixture.defaults.set(Data(json.utf8), forKey: HomeLayoutStore.key)
        let host = host([
            homePlugin("battery", sizes: [.small, .wide], name: "배터리"),
            homePlugin("clipboard", sizes: [.small, .wide], name: "클립보드"),
            homePlugin("cpu", sizes: [.small], name: "CPU"),
        ] + Self.symbolPlugins)
        host.home.beginEditing()
        _ = host.home.add("agents")
        let image = try render(HomeView(host: host), name: "R36-render-edit-T116.png")
        // Along the middle of the first row, every edge from the black gap into a tile or a free
        // slot is on a cell edge.
        let y = Int(HomeGrid.length(2) / 2)
        var edges: [Int] = []
        for x in 1..<Int(image.size.width) where image.brightness(x - 1, y) < 12 && image.brightness(x, y) >= 24 {
            edges.append(x)
        }
        #expect(!edges.isEmpty)
        for edge in edges {
            let cell = (CGFloat(edge) / (2 * (HomeGrid.unit + HomeGrid.gap))).rounded() * 2 * (HomeGrid.unit + HomeGrid.gap)
            #expect(abs(CGFloat(edge) - cell) <= 1, "edge at \(edge) pt, edges \(edges)")
        }
        #expect(host.home.tiles.map(\.placement.origin.column).sorted() == [0, 2, 4, 6])
        _ = try render(HomeView(host: self.host([
            homePlugin("battery", sizes: [.small], name: "배터리"),
        ] + Self.symbolPlugins)), name: "R36-render-home-T116.png")
    }

    // MARK: Helpers

    /// Plugins without a tile of their own, with the symbols of the app's coding agents, Hello and a
    /// third-party one.
    static var symbolPlugins: [HomePlugin] {
        [("agents", "코딩 에이전트", "apple.terminal", true), ("hello", "인사", "hand.wave", false), ("notes", "메모", "note.text", true)].map { id, name, symbol, tab in
            HomePlugin(pluginID: id, name: name, symbol: symbol, tab: tab ? PluginTab(title: name, symbol: symbol) { Text(name) } : nil, tile: nil)
        }
    }

    /// Room over the home in bubble renders, where the notch has its band and padding.
    static let bubbleRoom: CGFloat = 40

    /// Renders the home under `bubbleRoom` and returns the box of light (bubble) ink above the
    /// strip, which nothing but the bubble draws; nil when there is none.
    func bubble(_ host: NotchHostModel, _ name: String) throws -> CGRect? {
        try bubbleInk(host, name)?.box
    }

    /// The bubble's box as `bubble(_:_:)` finds it, and the rightmost column of dark (name) ink
    /// across its middle rows, where the capsule's rounded ends leave no black corners.
    func bubbleInk(_ host: NotchHostModel, _ name: String) throws -> (box: CGRect, inkEnd: Int)? {
        let image = try render(HomeView(host: host).padding(.top, Self.bubbleRoom), name: name)
        var box: CGRect?
        for y in 0..<Int(Self.bubbleRoom) {
            for x in 0..<Int(image.size.width) where image.brightness(x, y) > 200 {
                box = (box ?? CGRect(x: x, y: y, width: 1, height: 1)).union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let box else { return nil }
        // Dark text on the light fill: the name's ink inside the box.
        let ink = (Int(box.minY) + 2..<Int(box.maxY) - 2).flatMap { y in
            (Int(box.minX) + 4..<Int(box.maxX) - 4).filter { image.brightness($0, y) < 120 }
        }
        #expect(ink.count > 20, "no text in the bubble \(box)")
        let middle = Int(box.minY + box.height / 4)..<Int(box.maxY - box.height / 4)
        let inkEnd = (Int(box.minX) + 4..<Int(box.maxX) - 1).last { x in middle.contains { image.brightness(x, $0) < 120 } }
        return (box, inkEnd ?? Int(box.minX))
    }

    /// The bubble sits over the strip's `index`th icon, inside the strip's width and above it.
    func expectBubble(_ box: CGRect, over index: Int) {
        let left = CGFloat(index) * (HomeGrid.stripIcon + HomeGrid.gap)
        #expect(box.minX <= left + HomeGrid.stripIcon && box.maxX >= left, "bubble \(box) not over icon \(index)")
        #expect(box.minX >= 0 && box.maxX <= HomeGrid.size.width, "bubble \(box) outside the strip")
        #expect(box.maxY <= Self.bubbleRoom, "bubble \(box) over the icons")
        #expect(box.height >= 14, "bubble \(box)")
    }

    struct Pixels {
        let size: CGSize
        let scale: Int
        let data: [UInt8]
        let width: Int

        /// The brightest channel of the pixel at (`x`, `y`) in points from the top left.
        func brightness(_ x: Int, _ y: Int) -> Int {
            let i = ((y * scale) * width + x * scale) * 4
            return Int(max(data[i], data[i + 1], data[i + 2]))
        }
    }

    /// Draws `view` on black offscreen; writes it to NOTCH_RENDER_DIR as `name` when that is set.
    func render(_ view: some View, name: String) throws -> Pixels {
        let hosting = NSHostingView(rootView: view.background(Color.black).environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        settle(hosting)
        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        if let directory = ProcessInfo.processInfo.environment["NOTCH_RENDER_DIR"] {
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name))
        }
        let image = try #require(rep.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(size: hosting.bounds.size, scale: Int((CGFloat(image.width) / hosting.bounds.width).rounded()), data: pixels, width: image.width)
    }

    func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.05)
        view.layoutSubtreeIfNeeded()
    }

    func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }
}
