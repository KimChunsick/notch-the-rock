import AppKit
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import Agents

/// The app's tile frames (`HomeGrid` in the app: 40 pt units 10 pt apart).
private let tileFrames: [TileSize: CGSize] = [
    .small: CGSize(width: 90, height: 90),
    .wide: CGSize(width: 190, height: 90),
]

/// A tile on the home's black, in its frame with the tiles' fill, for the renders.
@MainActor
private func onHome(_ tiles: [(AgentsTile, TileSize)]) -> some View {
    HStack(alignment: .top, spacing: 10) {
        ForEach(Array(tiles.enumerated()), id: \.offset) { _, entry in
            entry.0
                .frame(width: tileFrames[entry.1]?.width, height: tileFrames[entry.1]?.height)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
    .padding(12)
    .background(.black)
}

/// What the home tile shows of the open sessions, with marks given by the test.
@MainActor
@Suite struct TileTests {
    let logos = FakeLogos()
    let world = SessionWorld()
    let list = AgentSessionList()

    init() {
        // Claude's mark is a template drawn black (tinted white on the notch); Codex's keeps its colour.
        logos.images[.claude] = solidLogo(.black, template: true)
        logos.images[.codex] = solidLogo(AlertTests.magenta, template: false)
        world.attach(to: list)
    }

    func tile(_ size: TileSize) -> AgentsTile {
        AgentsTile(sessions: list, logos: logos, size: size)
    }

    /// Claude waiting for an approval, Codex at work and Claude idle, changed in that order: the list
    /// has the idle one first, the tile the waiting one.
    func addThree() {
        list.update(AgentSession.Key(agent: .claude, id: "c1"), folder: "tide-pool", state: .awaitingApproval)
        world.now += 1
        list.update(AgentSession.Key(agent: .codex, id: "x1"), folder: "notch-the-rock", state: .working)
        world.now += 1
        list.update(AgentSession.Key(agent: .claude, id: "c2"), folder: "rock-garden", state: .idle)
    }

    /// The tile at its ideal size on black, laid out as the host lays it out.
    func drawn(_ size: TileSize) -> NSView {
        layOut(tile(size), in: NSHostingView(rootView: tile(size)).fittingSize)
    }

    static func white(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { min(r, g, b) > 200 }
    static func orange(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g > 100 && g < 190 && b < 90 }
    static func green(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { g > 150 && r < 130 && b < 150 }
    static func red(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Bool { r > 200 && g < 100 && b < 100 }

    @Test func R44__wide_tile_lists_waiting_then_working_then_idle_sessions_with_logo_folder_and_state() throws {
        addThree()
        #expect(list.sessions.map(\.folder) == ["rock-garden", "notch-the-rock", "tide-pool"])
        let wide = tile(.wide)
        #expect(wide.rows.map(\.folder) == ["tide-pool", "notch-the-rock", "rock-garden"])
        #expect(wide.rows.map(\.state.title) == ["승인 대기", "작업 중", "대기 중"])
        #expect(wide.more == 0)
        let ideal = NSHostingView(rootView: wide).fittingSize
        #expect(ideal.width <= 190 && ideal.height <= 90, "\(ideal)")

        // Each row starts with its agent's mark: 14 pt at the padding, rows 16 pt tall 3 pt apart.
        let view = drawn(.wide)
        let marks = [(14.0, AlertTests.light), (33.0, AlertTests.pink), (52.0, AlertTests.light)]
        for (index, (y, matches)) in marks.enumerated() {
            let share = try share(of: CGRect(x: 13, y: y, width: 8, height: 8), in: view, where: matches)
            #expect(share > 0.9, "row \(index) mark: \(share)")
        }
        // The state is written in its colour at the right of its row.
        #expect(try share(of: CGRect(x: 110, y: 10, width: 70, height: 16), in: view, where: Self.orange) > 0)
        #expect(try share(of: CGRect(x: 110, y: 29, width: 70, height: 16), in: view, where: Self.green) > 0)

        // Five sessions: the three most relevant and how many more.
        world.now += 1
        list.update(AgentSession.Key(agent: .codex, id: "x2"), folder: "deep-sea", state: .awaitingAnswer)
        world.now += 1
        list.update(AgentSession.Key(agent: .codex, id: "x3"), folder: "a-very-long-project-folder-name-that-does-not-fit", state: .working)
        let five = tile(.wide)
        #expect(five.rows.map(\.folder) == ["deep-sea", "tide-pool", "a-very-long-project-folder-name-that-does-not-fit"])
        #expect(five.more == 2)
        let fiveSize = NSHostingView(rootView: five).fittingSize
        #expect(fiveSize.width <= 190 && fiveSize.height <= 90, "\(fiveSize)")

        let threeOnly = AgentSessionList()
        threeOnly.update(AgentSession.Key(agent: .claude, id: "c1"), folder: "tide-pool", state: .awaitingApproval)
        threeOnly.update(AgentSession.Key(agent: .codex, id: "x1"), folder: "notch-the-rock", state: .working)
        threeOnly.update(AgentSession.Key(agent: .claude, id: "c2"), folder: "rock-garden", state: .idle)
        try capture(
            onHome([(AgentsTile(sessions: threeOnly, logos: logos, size: .wide), .wide), (five, .wide)]),
            named: "R44-render-wide-T140"
        )
    }

    @Test func R44__small_tile_shows_the_agents_logos_the_session_count_and_the_waiting_count() throws {
        addThree()
        let small = tile(.small)
        #expect(small.agents == [.claude, .codex])
        #expect(small.count == 3)
        #expect(small.waiting == 1)
        let ideal = NSHostingView(rootView: small).fittingSize
        #expect(ideal.width <= 90 && ideal.height <= 90, "\(ideal)")

        // Both marks, 18 pt and 4 pt apart, centred in the 70 pt column; the waiting count is
        // highlighted.
        let view = drawn(.small)
        let left = (ideal.width - 40) / 2
        #expect(try share(of: CGRect(x: left + 5, y: 11, width: 8, height: 8), in: view, where: AlertTests.light) > 0.9)
        #expect(try share(of: CGRect(x: left + 27, y: 11, width: 8, height: 8), in: view, where: AlertTests.pink) > 0.9)
        #expect(try share(of: CGRect(x: 0, y: 40, width: ideal.width, height: ideal.height - 40), in: view, where: Self.orange) > 0)

        // Only the agents with sessions show their mark.
        let codexOnly = AgentSessionList()
        codexOnly.update(AgentSession.Key(agent: .codex, id: "x1"), folder: "notch-the-rock", state: .working)
        let codexTile = AgentsTile(sessions: codexOnly, logos: logos, size: .small)
        #expect(codexTile.agents == [.codex])
        #expect(codexTile.waiting == 0)
        try capture(onHome([(small, .small), (codexTile, .small)]), named: "R44-render-small-T140")
    }

    @Test func R44__an_empty_tile_dims_both_logos_and_says_no_session_is_open() throws {
        let wide = tile(.wide), small = tile(.small)
        #expect(wide.rows.isEmpty && wide.more == 0)
        #expect(small.agents.isEmpty && small.count == 0 && small.waiting == 0)
        #expect(AgentsTile.emptyTitle == "진행 중인 세션이 없어요")
        for size in [TileSize.wide, .small] {
            let ideal = NSHostingView(rootView: tile(size)).fittingSize
            let frame = try #require(tileFrames[size])
            #expect(ideal.width <= frame.width && ideal.height <= frame.height, "\(size): \(ideal)")
            // Both marks are drawn, dimmed: no full white and no full pink, but a dark pink.
            let view = drawn(size)
            let all = CGRect(origin: .zero, size: ideal)
            #expect(try share(of: all, in: view, where: Self.white) == 0, "\(size)")
            #expect(try share(of: all, in: view, where: AlertTests.pink) == 0, "\(size)")
            #expect(try share(of: all, in: view) { r, g, b in r > 50 && b > 50 && g < 30 } > 0, "\(size)")
        }
        try capture(onHome([(wide, .wide), (small, .small)]), named: "R44-render-empty-T140")
    }

    @Test func R44__tapping_the_tile_opens_the_agents_screen() throws {
        let host = FakeHost()
        let paths = makeSocketPath()
        defer { try? FileManager.default.removeItem(atPath: paths.folder) }
        let directory = try makeDirectory()
        let plugin = AgentsPlugin(
            context: try makeContext(host: host, directory: directory),
            socketPath: paths.socket,
            settingsURL: directory.appendingPathComponent("settings.json"),
            claudeExecutable: nil,
            activator: FakeActivator(),
            codexEndpoint: CodexEndpoint(home: directory),
            codexExecutable: nil,
            codexLauncher: FakeLauncher(socketPath: ""),
            codexTerminal: { _ in nil }
        )
        let tile = try #require(plugin.tile)
        #expect(tile.supportedSizes == [.wide, .small])
        #expect(tile.defaultSize == .wide)
        // The host opens the plugin's screen when its tile is tapped: the screen exists and the tile
        // has no control of its own that would take the tap.
        #expect(plugin.expandedTab?.title == AgentsPlugin.manifest.name)
        plugin.bridge.screen.sessions.update(AgentSession.Key(agent: .codex, id: "x1"), folder: "notch-the-rock", state: .awaitingAnswer)
        for size in tile.supportedSizes {
            let frame = try #require(tileFrames[size])
            let ideal = NSHostingView(rootView: tile.content(size)).fittingSize
            #expect(ideal.width > 0 && ideal.width <= frame.width && ideal.height > 0 && ideal.height <= frame.height, "\(size): \(ideal)")
            #expect(pinnedControls(in: layOut(tile.content(size), in: frame)).controls.isEmpty, "\(size)")
        }
    }
}
