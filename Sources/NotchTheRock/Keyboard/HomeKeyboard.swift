import AppKit
import Observation

/// Keyboard state of the home: where the focus ring is, and the quick search while it is open.
/// `NotchHostModel` owns it and clears it when the notch collapses.
@MainActor
@Observable
final class HomeKeyboard {
    /// The plugin whose tile or strip icon has the focus ring; nil until the hotkey or an arrow key.
    var focus: String?
    /// The quick search text while the search is open (possibly empty); nil when it is closed.
    var query: String? {
        didSet {
            guard query == nil else { return }
            selection = nil
            openingKey = nil
        }
    }
    /// The chosen search result; the first result when nil or no longer among the results.
    var selection: String?
    /// The key press that opened the quick search, until the search field takes the focus and
    /// types it through its text input, where an input method composes it like any other key.
    @ObservationIgnored var openingKey: NSEvent?

    func reset() {
        focus = nil
        query = nil
    }
}

extension NotchHostModel {
    /// Plugins whose name matches the quick search, in home order. Only plugins with a screen are
    /// listed: a display-only tile has nothing to open.
    var searchResults: [HomeEntry] {
        guard let query = keyboard.query else { return [] }
        return homeEntries.filter { $0.opensDetail && PluginNameSearch.matches(name: $0.name, query: query) }
    }

    var selectedResult: HomeEntry? {
        let results = searchResults
        return results.first { $0.pluginID == keyboard.selection } ?? results.first
    }

    /// Acts on a key pressed while the expanded notch is key, and says whether the key was used;
    /// unused keys go on to the focused control (the search field, a plugin's own view).
    ///
    /// - On a plugin's screen and in edit mode only Esc is the notch's (`escape()`).
    /// - On the home, arrows move the focus ring (`HomeFocusMap`), Enter opens the focused plugin,
    ///   Esc collapses, and letters or digits open an empty quick search; the search field then
    ///   takes that key press (`HomeKeyboard.openingKey`).
    /// - In the quick search, ↑↓ choose a result and Enter opens it; Esc closes the search, and so
    ///   does Backspace once the field is empty. Typing and ←→ belong to the field.
    func handleKey(_ key: HomeKey) -> Bool {
        guard state == .expanded else { return false }
        guard screen == .home, !home.isEditing else {
            guard key == .escape else { return false }
            escape()
            return true
        }
        if let query = keyboard.query {
            return handleSearchKey(key, query: query)
        }
        switch key {
        case .up: moveFocus(.up)
        case .down: moveFocus(.down)
        case .left: moveFocus(.left)
        case .right: moveFocus(.right)
        case .enter:
            guard let focus = keyboard.focus, let entry = homeEntries.first(where: { $0.pluginID == focus }) else { return false }
            if entry.opensDetail { open(pluginID: entry.pluginID) }
        case .escape:
            escape()
        case .text:
            keyboard.query = ""
        case .backspace:
            return false
        }
        return true
    }

    private func handleSearchKey(_ key: HomeKey, query: String) -> Bool {
        switch key {
        case .up, .down:
            let results = searchResults
            guard let current = selectedResult, let index = results.firstIndex(of: current) else { return true }
            let next = key == .up ? max(index - 1, 0) : min(index + 1, results.count - 1)
            keyboard.selection = results[next].pluginID
        case .enter:
            guard let result = selectedResult else { return true }
            open(pluginID: result.pluginID)
        case .escape:
            keyboard.query = nil
        case .backspace:
            guard query.isEmpty else { return false }
            keyboard.query = nil
        case .left, .right, .text:
            return false
        }
        return true
    }

    /// The strip icon to scroll into view: the focused plugin when it is in the strip, which shows as
    /// many icons as the grid is wide, so a focus further right would otherwise be out of sight.
    var listScrollTarget: String? {
        guard let focus = keyboard.focus, home.list.contains(where: { $0.pluginID == focus }) else { return nil }
        return focus
    }

    private func moveFocus(_ direction: HomeDirection) {
        let map = HomeFocusMap(tiles: home.tiles.map(\.placement), list: home.list.map(\.pluginID))
        keyboard.focus = map.target(from: keyboard.focus, direction)
    }
}
