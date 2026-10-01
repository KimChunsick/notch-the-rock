import AppKit
import SwiftUI

/// The quick search in place of the home's grid and list: the field with what was typed and the
/// plugins whose name matches. ↑↓, Enter, Esc and Backspace on an empty field come through
/// `NotchHostModel.handleKey(_:)`; typing goes to the field, so Korean is composed as usual.
struct QuickSearchView: View {
    let host: NotchHostModel

    private static let visibleRows = 6

    var body: some View {
        let results = host.searchResults
        VStack(alignment: .leading, spacing: HomeGrid.gap) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.6))
                QuickSearchField(keyboard: host.keyboard)
            }
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.14)))
            if results.isEmpty {
                Text("이름이 맞는 플러그인이 없어요")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else if results.count > Self.visibleRows {
                // The selected result stays in sight: when the list appears (a broader query keeps
                // a selection made further down), when the results change and when it moves.
                ScrollViewReader { proxy in
                    ScrollView { rows(results) }
                        .scrollIndicators(.never)
                        .frame(height: CGFloat(Self.visibleRows) * 28 + CGFloat(Self.visibleRows - 1) * 4)
                        .onAppear { scrollToSelection(proxy) }
                        .onChange(of: results.map(\.pluginID)) { scrollToSelection(proxy) }
                        .onChange(of: host.selectedResult?.pluginID) { scrollToSelection(proxy) }
                }
            } else {
                rows(results)
            }
        }
        .foregroundStyle(.white)
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy) {
        if let selected = host.selectedResult?.pluginID { proxy.scrollTo(selected) }
    }

    private func rows(_ results: [HomeEntry]) -> some View {
        let selected = host.selectedResult?.pluginID
        return VStack(spacing: 4) {
            ForEach(results, id: \.pluginID) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.symbol)
                        .frame(width: 20)
                    Text(entry.name)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if entry.pluginID == selected {
                        Image(systemName: "return")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(entry.pluginID == selected ? 0.24 : 0.08)))
                .contentShape(Rectangle())
                .onTapGesture { host.open(pluginID: entry.pluginID) }
                .id(entry.pluginID)
            }
        }
    }
}

/// The search text field, in AppKit so that it takes the focus and the opening key press in the
/// same turn as it appears, before the next key press arrives.
private struct QuickSearchField: NSViewRepresentable {
    let keyboard: HomeKeyboard

    func makeNSView(context: Context) -> QuickSearchTextField {
        let field = QuickSearchTextField()
        field.keyboard = keyboard
        field.stringValue = keyboard.query ?? ""
        field.placeholderString = "플러그인 이름"
        field.font = .systemFont(ofSize: 14, weight: .medium)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        // White text and caret on the notch's black.
        field.appearance = NSAppearance(named: .darkAqua)
        return field
    }

    func updateNSView(_ field: QuickSearchTextField, context: Context) {
        field.keyboard = keyboard
        // While the field is edited its text is the query; set from outside only otherwise.
        if field.currentEditor() == nil, let query = keyboard.query, field.stringValue != query {
            field.stringValue = query
        }
    }
}

/// Takes the focus with the caret after the text once it is in a window, then types the key press
/// that opened the search (`HomeKeyboard.openingKey`) through its field editor, where an input
/// method gets it like any other key: ㄴ then ㅏ composes 나. Everything typed, the composition
/// included, becomes the query.
///
/// The field follows the window's shared field editor only while it edits with it: from every time
/// it takes the focus (entering its window, Tab back, a click) until its editing ends.
final class QuickSearchTextField: NSTextField {
    weak var keyboard: HomeKeyboard?
    private var editing: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unfollow()
        guard let window, window.makeFirstResponder(self), let editor = currentEditor() as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        guard let opening = keyboard?.openingKey else { return }
        keyboard?.openingKey = nil
        editor.keyDown(with: opening)
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let editor = currentEditor() as? NSTextView { follow(editor) }
        return true
    }

    override func textDidEndEditing(_ notification: Notification) {
        // Before AppKit empties the shared field editor.
        unfollow()
        super.textDidEndEditing(notification)
    }

    /// Copies the field editor's text into the query now and on every change of its storage, a
    /// composition included: `textDidChange` does not come for marked text.
    private func follow(_ editor: NSTextView) {
        unfollow()
        editing = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification,
            object: editor.textStorage,
            queue: nil
        ) { [weak self, weak editor] _ in
            MainActor.assumeIsolated {
                guard let self, let editor else { return }
                self.copyQuery(from: editor)
            }
        }
        copyQuery(from: editor)
    }

    /// The field editor's text is the query while the search is open.
    private func copyQuery(from editor: NSTextView) {
        guard let keyboard, keyboard.query != nil, keyboard.query != editor.string else { return }
        keyboard.query = editor.string
    }

    private func unfollow() {
        if let editing { NotificationCenter.default.removeObserver(editing) }
        editing = nil
    }
}

extension View {
    /// The keyboard focus ring around a home tile or row.
    func homeFocusRing(_ shown: Bool, cornerRadius: CGFloat) -> some View {
        overlay {
            if shown {
                RoundedRectangle(cornerRadius: cornerRadius + 3, style: .continuous)
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
        }
    }
}
