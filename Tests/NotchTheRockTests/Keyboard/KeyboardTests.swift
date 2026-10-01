import AppKit
import Carbon.HIToolbox
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Stands in for Carbon: records what is registered, refuses the shortcuts it is told to, and
/// presses the registered one on demand. No test registers a real global hotkey.
@MainActor
final class FakeRegistrar: HotkeyRegistrar {
    var refused: Set<KeyShortcut> = []
    private(set) var registered: KeyShortcut?
    private(set) var history: [String] = []
    private var pressed: (@MainActor () -> Void)?

    func register(_ shortcut: KeyShortcut, pressed: @escaping @MainActor () -> Void) -> Bool {
        history.append("register \(shortcut.display)")
        guard !refused.contains(shortcut) else { return false }
        registered = shortcut
        self.pressed = pressed
        return true
    }

    func unregister() {
        if let registered { history.append("unregister \(registered.display)") }
        registered = nil
        pressed = nil
    }

    func press() {
        pressed?()
    }
}

/// The global hotkey, keyboard navigation of the home and quick search.
@MainActor
struct KeyboardTests {
    let fixture = HomeDefaults()

    let optionSpace = KeyShortcut(keyCode: UInt16(kVK_Space), modifiers: [.control, .option])
    let commandK = KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .shift])

    /// A large tile (A), two small ones (B, C) and a wide one (D) under them, then two list rows
    /// (E, F) and a display-only tile (G) that no longer fits the grid.
    ///
    ///     ┌─────────┬────┬────┐
    ///     │         │ B  │ C  │
    ///     │    A    ├────┴────┤
    ///     │         │    D    │
    ///     └─────────┴─────────┘
    ///     E 메모
    ///     F Weather
    func sampleHost() -> NotchHostModel {
        let host = NotchHostModel(now: { .now }, homeStore: fixture.store)
        host.plugins = [
            homePlugin("A", sizes: [.large], name: "배터리"),
            homePlugin("B", sizes: [.small], name: "Clipboard"),
            homePlugin("C", sizes: [.small], name: "날씨"),
            homePlugin("D", sizes: [.wide], name: "미디어"),
            homePlugin("E", sizes: [], name: "메모"),
            homePlugin("F", sizes: [], name: "Weather"),
        ]
        return host
    }

    // MARK: Shortcut

    @Test func R17__shortcut_encodes_decodes_and_displays_control_option_N() throws {
        let standard = KeyShortcut.default
        #expect(standard.keyCode == UInt16(kVK_ANSI_N))
        #expect(standard.modifiers == [.control, .option])
        #expect(standard.display == "⌃⌥N")
        #expect(standard.carbonModifiers == UInt32(controlKey | optionKey))
        #expect(KeyShortcut(encoded: standard.encoded) == standard)
        #expect(KeyShortcut(encoded: commandK.encoded) == commandK)
        #expect(commandK.display == "⇧⌘K")
        #expect(optionSpace.display == "⌃⌥Space")
        #expect(KeyShortcut(encoded: Data("garbage".utf8)) == nil)
    }

    @Test func R17__recording_needs_command_option_or_control() {
        #expect(KeyShortcut.record(keyCode: UInt16(kVK_ANSI_N), modifierFlags: [.control, .option]) == .shortcut(.default))
        #expect(KeyShortcut.record(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.shift]) == .needsModifier)
        #expect(KeyShortcut.record(keyCode: UInt16(kVK_ANSI_K), modifierFlags: []) == .needsModifier)
        #expect(KeyShortcut.record(keyCode: UInt16(kVK_ANSI_K), modifierFlags: [.command, .shift, .capsLock]) == .shortcut(commandK))
        // Fn and a key without a name of its own are refused.
        #expect(KeyShortcut.record(keyCode: 0x7F, modifierFlags: [.command]) == .unsupportedKey)
    }

    // MARK: Registration

    @Test func R17__changing_the_shortcut_registers_the_new_one_and_unregisters_the_old() {
        defer { fixture.cleanUp() }
        let registrar = FakeRegistrar()
        let hotkey = GlobalHotkey(defaults: fixture.defaults, registrar: registrar)
        #expect(hotkey.shortcut == .default)
        var presses = 0
        hotkey.start { presses += 1 }
        #expect(registrar.registered == .default)
        #expect(hotkey.isRegistered)

        #expect(hotkey.change(to: commandK))
        #expect(registrar.history == ["register ⌃⌥N", "unregister ⌃⌥N", "register ⇧⌘K"])
        #expect(registrar.registered == commandK)
        registrar.press()
        #expect(presses == 1)

        // Stored: the next launch starts with it.
        let next = GlobalHotkey(defaults: fixture.defaults, registrar: FakeRegistrar())
        #expect(next.shortcut == commandK)

        hotkey.reset()
        #expect(registrar.registered == .default)
        #expect(GlobalHotkey(defaults: fixture.defaults, registrar: FakeRegistrar()).shortcut == .default)
    }

    @Test func R17__refused_shortcut_keeps_the_old_one_and_reports_the_conflict() {
        defer { fixture.cleanUp() }
        let registrar = FakeRegistrar()
        registrar.refused = [optionSpace]
        let hotkey = GlobalHotkey(defaults: fixture.defaults, registrar: registrar)
        hotkey.start {}
        #expect(!hotkey.change(to: optionSpace))
        #expect(hotkey.refused == optionSpace)
        #expect(hotkey.shortcut == .default)
        #expect(registrar.registered == .default)
        #expect(GlobalHotkey(defaults: fixture.defaults, registrar: FakeRegistrar()).shortcut == .default)
        // A later change that works clears the message.
        #expect(hotkey.change(to: commandK))
        #expect(hotkey.refused == nil)
    }

    @Test func R17__recording_suspends_the_hotkey_and_resumes_it() {
        defer { fixture.cleanUp() }
        let registrar = FakeRegistrar()
        let hotkey = GlobalHotkey(defaults: fixture.defaults, registrar: registrar)
        hotkey.start {}
        hotkey.suspend()
        #expect(registrar.registered == nil)
        hotkey.resume()
        #expect(registrar.registered == .default)
    }

    // MARK: Hotkey and keyboard mode

    @Test func R17__hotkey_toggles_the_notch_in_keyboard_mode() {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        let registrar = FakeRegistrar()
        let hotkey = GlobalHotkey(defaults: fixture.defaults, registrar: registrar)
        hotkey.start { host.toggleFromKeyboard() }

        registrar.press()
        #expect(host.state == .expanded)
        #expect(host.screen == .home)
        #expect(host.keyboard.focus == "A")
        #expect(host.isHeldOpen)

        registrar.press()
        #expect(host.state == .collapsed)
        #expect(host.keyboard.focus == nil)

        // From a plugin screen the hotkey collapses too, and opens the home the next time.
        host.open(pluginID: "E")
        registrar.press()
        #expect(host.state == .collapsed)
        registrar.press()
        #expect(host.screen == .home)
    }

    @Test func R17__keys_map_to_navigation_and_text() {
        #expect(HomeKey(keyCode: 126, characters: nil, modifierFlags: [.numericPad, .function]) == .up)
        #expect(HomeKey(keyCode: 125, characters: nil, modifierFlags: []) == .down)
        #expect(HomeKey(keyCode: 123, characters: nil, modifierFlags: []) == .left)
        #expect(HomeKey(keyCode: 124, characters: nil, modifierFlags: []) == .right)
        #expect(HomeKey(keyCode: 36, characters: "\r", modifierFlags: []) == .enter)
        #expect(HomeKey(keyCode: 76, characters: "\u{3}", modifierFlags: []) == .enter)
        #expect(HomeKey(keyCode: 53, characters: "\u{1b}", modifierFlags: []) == .escape)
        #expect(HomeKey(keyCode: 51, characters: "\u{7f}", modifierFlags: []) == .backspace)
        #expect(HomeKey(keyCode: 0, characters: "a", modifierFlags: []) == .text("a"))
        #expect(HomeKey(keyCode: 0, characters: "A", modifierFlags: [.shift]) == .text("A"))
        #expect(HomeKey(keyCode: 0, characters: "ㅁ", modifierFlags: []) == .text("ㅁ"))
        // Shortcuts and non-letters are not typing.
        #expect(HomeKey(keyCode: 0, characters: "a", modifierFlags: [.command]) == nil)
        #expect(HomeKey(keyCode: 125, characters: nil, modifierFlags: [.control]) == nil)
        #expect(HomeKey(keyCode: 49, characters: " ", modifierFlags: []) == nil)
        #expect(HomeKey(keyCode: 48, characters: "\t", modifierFlags: []) == nil)
    }

    @Test func R17__arrows_move_focus_spatially_over_grid_and_list() {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        #expect(host.homeEntries.map(\.pluginID) == ["A", "B", "C", "D", "E", "F"])
        host.showHome()
        func press(_ key: HomeKey) -> String? {
            #expect(host.handleKey(key))
            return host.keyboard.focus
        }
        // The first arrow focuses the first entry.
        #expect(press(.right) == "A")
        #expect(press(.right) == "B")
        #expect(press(.right) == "C")
        #expect(press(.right) == "C")
        #expect(press(.down) == "D")
        #expect(press(.left) == "A")
        #expect(press(.up) == "A")
        // Down from the grid's last row enters the list; up from its first row goes back.
        #expect(press(.down) == "E")
        #expect(press(.down) == "F")
        #expect(press(.down) == "F")
        #expect(press(.left) == "F")
        #expect(press(.up) == "E")
        #expect(press(.up) == "A")
        #expect(press(.right) == "B")
        #expect(press(.down) == "D")
        #expect(press(.up) == "B")

        // Pure map: a grid without list stays put going down from the bottom row.
        let map = HomeFocusMap(
            tiles: [TilePlacement(pluginID: "X", size: .wide, origin: GridOrigin(column: 0, row: 0))],
            list: []
        )
        #expect(map.target(from: "X", .down) == "X")
        #expect(map.target(from: nil, .up) == "X")
        #expect(HomeFocusMap(tiles: [], list: []).target(from: nil, .down) == nil)
    }

    @Test func R17__enter_opens_the_focused_plugin_and_escape_twice_collapses() {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        host.toggleFromKeyboard()
        #expect(host.handleKey(.right))
        #expect(host.handleKey(.enter))
        #expect(host.screen == .detail(pluginID: "B"))
        // Arrows and typing on a plugin's screen belong to the plugin.
        #expect(!host.handleKey(.down))
        #expect(!host.handleKey(.text("a")))
        #expect(host.handleKey(.escape))
        #expect(host.screen == .home)
        #expect(host.state == .expanded)
        #expect(host.keyboard.focus == "B")
        #expect(host.handleKey(.escape))
        #expect(host.state == .collapsed)

        // Edit mode keeps its own keys; Esc finishes editing first.
        host.toggleFromKeyboard()
        host.home.beginEditing()
        #expect(!host.handleKey(.right))
        #expect(!host.handleKey(.text("a")))
        #expect(host.keyboard.query == nil)
        #expect(host.handleKey(.escape))
        #expect(!host.home.isEditing)
        #expect(host.state == .expanded)
    }

    @Test func R17__enter_on_a_display_only_tile_does_nothing() {
        defer { fixture.cleanUp() }
        let host = NotchHostModel(now: { .now }, homeStore: fixture.store)
        host.plugins = [homePlugin("T", sizes: [.small], tab: false, name: "시계")]
        host.toggleFromKeyboard()
        #expect(host.keyboard.focus == "T")
        #expect(host.handleKey(.enter))
        #expect(host.screen == .home)
        #expect(host.state == .expanded)
    }

    // MARK: Quick search

    @Test func R17__search_matches_names_in_korean_and_english() {
        #expect(PluginNameSearch.matches(name: "Weather", query: "wea"))
        #expect(PluginNameSearch.matches(name: "Weather", query: "THER"))
        #expect(!PluginNameSearch.matches(name: "Weather", query: "wx"))
        #expect(PluginNameSearch.matches(name: "날씨", query: "날씨"))
        #expect(PluginNameSearch.matches(name: "날씨", query: "씨"))
        // Initial consonants alone, and a syllable still being composed.
        #expect(PluginNameSearch.matches(name: "날씨", query: "ㄴㅆ"))
        #expect(PluginNameSearch.matches(name: "날씨", query: "나"))
        #expect(PluginNameSearch.matches(name: "미디어 키", query: "ㅁㄷ"))
        #expect(!PluginNameSearch.matches(name: "날씨", query: "ㅁ"))
        #expect(!PluginNameSearch.matches(name: "날씨", query: "낫"))
        #expect(PluginNameSearch.matches(name: "날씨", query: ""))
    }

    @Test func R17__typing_opens_search_and_enter_opens_the_selected_result() {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        host.toggleFromKeyboard()
        #expect(host.handleKey(.text("w")))
        #expect(host.keyboard.query == "w")
        #expect(host.searchResults.map(\.pluginID) == ["F"])

        // The field takes further typing and Backspace while it has text.
        #expect(!host.handleKey(.text("x")))
        #expect(!host.handleKey(.backspace))
        host.keyboard.query = "ㅁ"
        #expect(host.searchResults.map(\.pluginID) == ["D", "E"])
        #expect(host.selectedResult?.pluginID == "D")
        #expect(host.handleKey(.down))
        #expect(host.selectedResult?.pluginID == "E")
        #expect(host.handleKey(.down))
        #expect(host.selectedResult?.pluginID == "E")
        #expect(host.handleKey(.up))
        #expect(host.selectedResult?.pluginID == "D")
        #expect(host.handleKey(.down))
        #expect(host.handleKey(.enter))
        #expect(host.screen == .detail(pluginID: "E"))
        #expect(host.keyboard.query == nil)

        // No match: nothing to open.
        host.showHome()
        #expect(host.handleKey(.text("q")))
        host.keyboard.query = "qqq"
        #expect(host.searchResults.isEmpty)
        #expect(host.handleKey(.enter))
        #expect(host.screen == .home)
    }

    @Test func R17__escape_clears_the_search_first_and_backspace_on_empty_closes_it() {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        host.toggleFromKeyboard()
        #expect(host.handleKey(.text("날")))
        #expect(host.handleKey(.escape))
        #expect(host.keyboard.query == nil)
        #expect(host.state == .expanded)

        #expect(host.handleKey(.text("a")))
        host.keyboard.query = ""
        #expect(host.handleKey(.backspace))
        #expect(host.keyboard.query == nil)
        #expect(host.state == .expanded)
        #expect(host.handleKey(.escape))
        #expect(host.state == .collapsed)
    }

    // MARK: Programmatic open

    @Test func R17__programmatic_open_stays_open_until_the_pointer_enters_and_leaves() {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        let notchRect = CGRect(x: 646, y: 924, width: 179, height: 32)
        let home = NotchLayout.metrics(for: .expanded, notch: notchRect.size, hasActivity: false, content: CGSize(width: 390, height: 200))
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        let away = CGPoint(x: 100, y: 300)
        let inside = CGPoint(x: notchRect.midX, y: 800)

        host.showHome()
        #expect(host.isHeldOpen)
        // The pointer moving or clicking elsewhere does not end it, nor does a leave left over from
        // before the open.
        #expect(pointer.handle(.pointerMoved, at: away) == nil)
        #expect(pointer.handle(.pointerMoved, at: CGPoint(x: 1200, y: 500)) == nil)
        host.pointerLeft()
        #expect(host.state == .expanded)

        // Entering and then leaving does.
        #expect(pointer.handle(.pointerMoved, at: inside) == .enter)
        host.setHovering(true)
        #expect(!host.isHeldOpen)
        #expect(pointer.handle(.pointerMoved, at: away) == .leave)
        host.pointerLeft()
        #expect(host.state == .collapsed)

        // A click outside ends a held notch; a hovered notch is left to the pointer.
        host.open(pluginID: "E")
        host.clickedOutside()
        #expect(host.state == .collapsed)
        host.setHovering(true)
        host.clickedOutside()
        #expect(host.state == .expanded)
        host.pointerLeft()
        #expect(host.state == .collapsed)

        // A link while the pointer is on the notch is plain hovering.
        host.setHovering(true)
        host.open(pluginID: "F")
        #expect(!host.isHeldOpen)
    }

    // MARK: Renders

    /// The focused home, the search overlay and the settings row, written only when
    /// NOTCH_HOME_CAPTURE_DIR is set.
    @Test func R17__offscreen_renders_of_focus_search_and_settings() throws {
        defer { fixture.cleanUp() }
        guard let directory = ProcessInfo.processInfo.environment["NOTCH_HOME_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let host = sampleHost()
        host.toggleFromKeyboard()
        _ = host.handleKey(.right)
        _ = host.handleKey(.down)
        try render(HomeView(host: host).padding(16).background(Color.black), to: folder.appendingPathComponent("R17-render-home-focus-T38.png"))

        _ = host.handleKey(.text("ㅁ"))
        _ = host.handleKey(.down)
        try render(HomeView(host: host).padding(16).background(Color.black), to: folder.appendingPathComponent("R17-render-search-T38.png"))

        let registrar = FakeRegistrar()
        registrar.refused = [optionSpace]
        let hotkey = GlobalHotkey(defaults: fixture.defaults, registrar: registrar)
        hotkey.start {}
        _ = hotkey.change(to: optionSpace)
        try render(
            Form { Section { HotkeySettingsRow(hotkey: hotkey) } }.formStyle(.grouped).frame(width: 560),
            to: folder.appendingPathComponent("R17-render-settings-T38.png")
        )
    }

    private func render(_ view: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
