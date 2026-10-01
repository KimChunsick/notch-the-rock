import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Home → plugin screen → back or Esc, and the API the keyboard and URL plans call.
@MainActor
struct HomeNavigationTests {
    let fixture: HomeDefaults
    let host: NotchHostModel

    init() {
        let fixture = HomeDefaults()
        self.fixture = fixture
        host = NotchHostModel(now: { .now }, homeStore: fixture.store)
        host.plugins = [
            homePlugin("com.example.both", sizes: [.wide], name: "둘 다"),
            homePlugin("com.example.tab", sizes: [], name: "탭만"),
            homePlugin("com.example.tile", sizes: [.small], tab: false, name: "타일만"),
        ]
    }

    @Test func R16__tile_or_row_opens_the_plugin_screen_and_back_returns_home() {
        defer { fixture.cleanUp() }
        host.setHovering(true)
        #expect(host.screen == .home)
        host.open(pluginID: "com.example.both")
        #expect(host.screen == .detail(pluginID: "com.example.both"))
        host.back()
        #expect(host.screen == .home)
        host.open(pluginID: "com.example.tab")
        #expect(host.screen == .detail(pluginID: "com.example.tab"))
        #expect(host.state == .expanded)
    }

    @Test func R16__escape_returns_home_then_collapses() {
        defer { fixture.cleanUp() }
        host.open(pluginID: "com.example.tab")
        #expect(host.state == .expanded)
        host.escape()
        #expect(host.screen == .home)
        #expect(host.state == .expanded)
        host.escape()
        #expect(host.state == .collapsed)
    }

    @Test func R16__escape_in_edit_mode_finishes_editing_first() {
        defer { fixture.cleanUp() }
        host.showHome()
        host.home.beginEditing()
        host.escape()
        #expect(!host.home.isEditing)
        #expect(host.state == .expanded)
    }

    @Test func R16__open_unknown_or_display_only_plugin_shows_home() {
        defer { fixture.cleanUp() }
        host.open(pluginID: "com.example.tab")
        host.open(pluginID: "com.example.missing")
        #expect(host.screen == .home)
        #expect(host.state == .expanded)
        host.open(pluginID: "com.example.tile")
        #expect(host.screen == .home)
    }

    @Test func R16__show_home_expands_on_the_home() {
        defer { fixture.cleanUp() }
        #expect(host.state == .collapsed)
        host.showHome()
        #expect(host.state == .expanded)
        #expect(host.screen == .home)
    }

    @Test func R16__collapsing_returns_to_home_and_ends_editing() {
        defer { fixture.cleanUp() }
        host.open(pluginID: "com.example.both")
        host.setHovering(false)
        #expect(host.state == .collapsed)
        #expect(host.screen == .home)
        host.showHome()
        host.home.beginEditing()
        host.setHovering(false)
        #expect(!host.home.isEditing)
    }

    @Test func R16__plugin_asking_to_expand_opens_its_screen() {
        defer { fixture.cleanUp() }
        host.expand(toTabOf: "com.example.tab")
        #expect(host.state == .expanded)
        #expect(host.screen == .detail(pluginID: "com.example.tab"))
        host.collapse(from: "com.example.tab")
        #expect(host.state == .collapsed)
    }

    @Test func R16__screen_of_a_plugin_turned_off_falls_back_to_home() {
        defer { fixture.cleanUp() }
        host.open(pluginID: "com.example.tab")
        host.plugins = host.plugins.filter { $0.pluginID != "com.example.tab" }
        #expect(host.screen == .home)
    }

    @Test func R16__home_entries_list_the_grid_then_the_list_with_names() {
        defer { fixture.cleanUp() }
        #expect(host.homeEntries.map(\.pluginID) == ["com.example.both", "com.example.tile", "com.example.tab"])
        #expect(host.homeEntries.map(\.name) == ["둘 다", "타일만", "탭만"])
        #expect(host.homeEntries.map(\.opensDetail) == [true, false, true])
    }

    /// The catalog still hands over tabs only; they reach the home as list rows named by the tab.
    @Test func R16__tabs_from_the_catalog_become_list_rows() {
        defer { fixture.cleanUp() }
        host.tabs = [NotchHostModel.Tab(pluginID: "com.example.sample", tab: PluginTab(title: "Sample", symbol: "star") { EmptyView() })]
        #expect(host.homeEntries == [
            HomeEntry(pluginID: "com.example.sample", name: "Sample", symbol: "star", kind: .row, opensDetail: true),
        ])
        #expect(host.tabs.map(\.pluginID) == ["com.example.sample"])
    }
}
