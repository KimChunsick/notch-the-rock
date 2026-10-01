import AppKit
import SwiftUI

/// The quick search in place of the home's grid and list: the field with what was typed and the
/// plugins whose name matches. ↑↓, Enter, Esc and Backspace on an empty field come through
/// `NotchHostModel.handleKey(_:)`; typing goes to the field, so Korean is composed as usual.
struct QuickSearchView: View {
    let host: NotchHostModel
    @FocusState private var fieldFocused: Bool

    private static let visibleRows = 6

    var body: some View {
        let results = host.searchResults
        VStack(alignment: .leading, spacing: HomeGrid.gap) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.white.opacity(0.6))
                TextField("플러그인 이름", text: Binding(
                    get: { host.keyboard.query ?? "" },
                    // The field may report its text once more while the search closes.
                    set: { text in if host.keyboard.query != nil { host.keyboard.query = text } }
                ))
                .textFieldStyle(.plain)
                .focused($fieldFocused)
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
                ScrollViewReader { proxy in
                    ScrollView { rows(results) }
                        .scrollIndicators(.never)
                        .frame(height: CGFloat(Self.visibleRows) * 28 + CGFloat(Self.visibleRows - 1) * 4)
                        .onChange(of: host.selectedResult?.pluginID) { _, selected in
                            if let selected { proxy.scrollTo(selected) }
                        }
                }
            } else {
                rows(results)
            }
        }
        .foregroundStyle(.white)
        .onAppear { fieldFocused = true }
        // Becoming first responder selects the text typed so far; the next letter must add to it.
        .onChange(of: fieldFocused) { _, focused in
            if focused { Task { @MainActor in Self.moveCaretToEnd() } }
        }
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

    private static func moveCaretToEnd() {
        let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isKeyWindow }
        guard let editor = window?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
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
