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

    /// A large tile (A), two small ones (B, C) and a wide one (D) under them, then two strip icons
    /// (E, F) and a tile-only plugin (G) that no longer fits the grid.
    ///
    ///     ┌─────────┬────┬────┐
    ///     │         │ B  │ C  │
    ///     │    A    ├────┴────┤
    ///     │         │    D    │
    ///     └─────────┴─────────┘
    ///     (E) (F)
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
        // Down from the grid's last row enters the strip, left and right move along it, and up
        // goes back to the grid.
        #expect(press(.down) == "E")
        #expect(press(.right) == "F")
        #expect(press(.right) == "F")
        #expect(press(.down) == "F")
        #expect(press(.left) == "E")
        #expect(press(.left) == "E")
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

    @Test func R17__enter_on_a_tile_only_plugin_opens_its_fallback_screen() {
        defer { fixture.cleanUp() }
        let host = NotchHostModel(now: { .now }, homeStore: fixture.store)
        host.plugins = [homePlugin("T", sizes: [.small], tab: false, name: "시계")]
        host.toggleFromKeyboard()
        #expect(host.keyboard.focus == "T")
        #expect(host.handleKey(.enter))
        #expect(host.screen == .detail(pluginID: "T"))
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
        // The letter opens an empty search; the search field types it (see the text input tests).
        #expect(host.handleKey(.text("w")))
        #expect(host.keyboard.query == "")
        host.keyboard.query = "w"
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
        let home = NotchLayout.metrics(for: .expanded, notch: notchRect.size, content: CGSize(width: 390, height: 200))
        var pointer = NotchPointer(notchRect: notchRect, metrics: home)
        let now = ContinuousClock.now
        let away = CGPoint(x: 100, y: 300)
        let inside = CGPoint(x: notchRect.midX, y: 800)

        host.showHome()
        #expect(host.isHeldOpen)
        // The pointer moving or clicking elsewhere does not end it, nor does a leave left over from
        // before the open.
        #expect(pointer.handle(.pointerMoved, at: away, now: now) == nil)
        #expect(pointer.handle(.pointerMoved, at: CGPoint(x: 1200, y: 500), now: now) == nil)
        host.pointerLeft()
        #expect(host.state == .expanded)

        // Entering and then leaving does.
        #expect(pointer.handle(.pointerMoved, at: inside, now: now) == .enter)
        host.setHovering(true)
        #expect(!host.isHeldOpen)
        #expect(pointer.handle(.pointerMoved, at: away, now: now) == .leave)
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

    // MARK: Text input

    /// The notch window as an offscreen window showing the home, key as far as the routing goes.
    private func notchWindow(showing host: NotchHostModel) -> NSWindow {
        let hosting = NSHostingView(rootView: HomeView(host: host))
        hosting.frame = CGRect(x: 0, y: 0, width: 520, height: 420)
        let window = KeyNotchWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        settle(hosting)
        return window
    }

    /// Lets SwiftUI apply model changes to the views.
    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: .now + 0.05)
        view.layoutSubtreeIfNeeded()
    }

    private func keyDown(_ characters: String, _ keyCode: Int, in window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode)
        ))
    }

    @Test func R17__the_key_that_opens_the_search_is_typed_through_the_search_field() throws {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        host.toggleFromKeyboard()
        let window = notchWindow(showing: host)

        #expect(NotchWindowController.takesKey(try keyDown("s", kVK_ANSI_S, in: window), notchWindow: window, host: host))
        #expect(host.keyboard.query == "")
        settle(try #require(window.contentView))

        // The field has the focus and got the key through its field editor, where an input method
        // gets it like any other key. The test process has no active input method, so the key
        // arrives as typed text; under 2-set Hangul in the running app it starts a composition.
        let editor = try #require(window.firstResponder as? NSTextView)
        let delegate: AnyObject? = editor.delegate
        #expect(delegate is QuickSearchTextField)
        #expect(editor.string == "s" || editor.hasMarkedText())
        #expect(host.keyboard.query == editor.string)
        #expect(host.keyboard.openingKey == nil)
    }

    @Test func R17__enter_arrows_and_escape_belong_to_the_input_method_while_it_composes() throws {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        host.toggleFromKeyboard()
        host.keyboard.query = ""
        let window = notchWindow(showing: host)
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setMarkedText("ㄴ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        // The composition is already searched for (ㄴ matches 날씨 by its first consonant).
        #expect(host.keyboard.query == "ㄴ")

        let keys = [("\r", kVK_Return), ("", kVK_UpArrow), ("", kVK_DownArrow), ("", kVK_LeftArrow), ("\u{1b}", kVK_Escape)]
        for (characters, keyCode) in keys {
            #expect(!NotchWindowController.takesKey(try keyDown(characters, keyCode, in: window), notchWindow: window, host: host))
        }
        #expect(host.keyboard.query != nil)
        #expect(host.screen == .home)
        #expect(host.state == .expanded)

        // Once the composition ends, Esc is the search's again.
        editor.unmarkText()
        #expect(NotchWindowController.takesKey(try keyDown("\u{1b}", kVK_Escape, in: window), notchWindow: window, host: host))
        #expect(host.keyboard.query == nil)
    }

    @Test func R17__the_search_follows_the_field_again_after_it_loses_and_regains_the_focus() throws {
        defer { fixture.cleanUp() }
        let host = sampleHost()
        host.toggleFromKeyboard()
        let window = notchWindow(showing: host)
        #expect(NotchWindowController.takesKey(try keyDown("w", kVK_ANSI_W, in: window), notchWindow: window, host: host))
        settle(try #require(window.contentView))
        let editor = try #require(window.firstResponder as? NSTextView)
        let delegate: AnyObject? = editor.delegate
        let field = try #require(delegate as? QuickSearchTextField)
        #expect(host.keyboard.query == "w")

        // Tab ends the editing; the same field, still in its window, then takes the focus again.
        editor.insertTab(nil)
        #expect(host.keyboard.query == "w")
        #expect(window.makeFirstResponder(field))
        let refocused = try #require(window.firstResponder as? NSTextView)
        refocused.selectAll(nil)
        refocused.keyDown(with: try keyDown("c", kVK_ANSI_C, in: window))
        #expect(refocused.string == "c")
        #expect(host.keyboard.query == "c")
        #expect(host.searchResults.map(\.pluginID) == ["B"])

        // Enter opens what the field now says, not what it said before.
        #expect(NotchWindowController.takesKey(try keyDown("\r", kVK_Return, in: window), notchWindow: window, host: host))
        #expect(host.screen == .detail(pluginID: "B"))
    }

    // MARK: Long list

    /// A large tile and eight strip icons.
    func longListHost() -> NotchHostModel {
        let host = NotchHostModel(now: { .now }, homeStore: fixture.store)
        host.plugins = [homePlugin("A", sizes: [.large], name: "배터리")]
            + (1...8).map { homePlugin("L\($0)", sizes: [], name: "목록 \($0)") }
        return host
    }

    @Test func R17__focus_on_a_strip_icon_scrolls_it_into_view() {
        defer { fixture.cleanUp() }
        let host = longListHost()
        host.toggleFromKeyboard()
        #expect(host.keyboard.focus == "A")
        #expect(host.listScrollTarget == nil)

        _ = host.handleKey(.down)
        #expect(host.listScrollTarget == "L1")
        for _ in 0..<6 { _ = host.handleKey(.right) }
        #expect(host.keyboard.focus == "L7")
        #expect(host.listScrollTarget == "L7")
        _ = host.handleKey(.right)
        #expect(host.listScrollTarget == "L8")
    }

    @Test func R17__a_search_result_chosen_under_a_narrow_query_stays_in_view_when_the_query_broadens() throws {
        defer { fixture.cleanUp() }
        let host = longListHost()
        host.toggleFromKeyboard()
        let window = notchWindow(showing: host)
        let content = try #require(window.contentView)

        // Narrow the search to the eighth row and choose it.
        #expect(NotchWindowController.takesKey(try keyDown("8", kVK_ANSI_8, in: window), notchWindow: window, host: host))
        settle(content)
        #expect(host.searchResults.map(\.pluginID) == ["L8"])
        #expect(NotchWindowController.takesKey(try keyDown("", kVK_DownArrow, in: window), notchWindow: window, host: host))

        // Clearing the query lists all nine plugins, six at a time; the chosen row is the ninth.
        try #require(window.firstResponder as? NSTextView).deleteBackward(nil)
        settle(content)
        #expect(host.keyboard.query == "")
        let results = host.searchResults.map(\.pluginID)
        #expect(results.count == 9)
        #expect(host.selectedResult?.pluginID == "L8")
        let index = CGFloat(try #require(results.firstIndex(of: "L8")))
        let row = (index * 32)...(index * 32 + 28)

        let list = try #require(scrollViews(in: content).first)
        let document = try #require(list.documentView)
        let visible = list.documentVisibleRect
        let shown = document.isFlipped
            ? visible.minY...visible.maxY
            : (document.bounds.height - visible.maxY)...(document.bounds.height - visible.minY)
        #expect(shown.lowerBound <= row.lowerBound + 0.5 && row.upperBound <= shown.upperBound + 0.5, "rows \(shown) shown, chosen row at \(row)")
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews(in:))
    }

    // MARK: Recorder

    @Test func R17__recorder_takes_only_keys_of_its_window_and_stops_when_it_loses_key() throws {
        defer { fixture.cleanUp() }
        let registrar = FakeRegistrar()
        let hotkey = GlobalHotkey(defaults: fixture.defaults, registrar: registrar)
        hotkey.start {}
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let settings = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        settings.isReleasedWhenClosed = false
        let notch = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        let recorder = ShortcutRecorder()
        let controlOptionK = KeyShortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.control, .option])

        recorder.start(hotkey, in: settings)
        #expect(recorder.isRecording)
        #expect(registrar.registered == nil)
        // A key press for another window goes on to it untouched.
        #expect(!recorder.takesKey(try keyDown("k", kVK_ANSI_K, in: notch, flags: [.control, .option])))
        #expect(hotkey.shortcut == .default)
        // Another window resigning key changes nothing; the recorder's window resigning key stops it.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: notch)
        #expect(recorder.isRecording)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: settings)
        #expect(!recorder.isRecording)
        #expect(registrar.registered == .default)
        #expect(!recorder.takesKey(try keyDown("k", kVK_ANSI_K, in: settings, flags: [.control, .option])))
        #expect(hotkey.shortcut == .default)

        // A key press in its own window becomes the shortcut.
        recorder.start(hotkey, in: settings)
        #expect(recorder.takesKey(try keyDown("k", kVK_ANSI_K, in: settings, flags: [.control, .option])))
        #expect(hotkey.shortcut == controlOptionK)
        #expect(!recorder.isRecording)

        // Closing its window stops it too.
        recorder.start(hotkey, in: settings)
        settings.close()
        #expect(!recorder.isRecording)
        #expect(registrar.registered == controlOptionK)
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
        try render(HomeView(host: host).padding(NotchSizing.padding).background(Color.black), to: folder.appendingPathComponent("R17-render-home-focus-T72.png"))

        _ = host.handleKey(.text("ㅁ"))
        host.keyboard.query = "ㅁ"
        _ = host.handleKey(.down)
        try render(HomeView(host: host).padding(NotchSizing.padding).background(Color.black), to: folder.appendingPathComponent("R17-render-search-T72.png"))

        let long = longListHost()
        long.toggleFromKeyboard()
        _ = long.handleKey(.down)
        for _ in 0..<7 { _ = long.handleKey(.right) }
        try render(HomeView(host: long).padding(NotchSizing.padding).background(Color.black), to: folder.appendingPathComponent("R17-render-list-scroll-T72.png"))

        let registrar = FakeRegistrar()
        registrar.refused = [optionSpace]
        let hotkey = GlobalHotkey(defaults: fixture.defaults, registrar: registrar)
        hotkey.start {}
        _ = hotkey.change(to: optionSpace)
        try render(
            Form { Section { HotkeySettingsRow(hotkey: hotkey) } }.formStyle(.grouped).frame(width: 560),
            to: folder.appendingPathComponent("R17-render-settings-T72.png")
        )
    }

    private func render(_ view: some View, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        settle(hosting)
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}

/// Key for the routing without being on screen.
private final class KeyNotchWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
