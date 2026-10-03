import AppKit
import SwiftUI

/// Draws `content` with the time the unsaved notice of `history` is judged at, and again when the
/// notice is due. Until then the date is the moment the count rose, so a list written within the
/// delay never shows the notice. An explicit timeline is not drawn at its last date, so a date that
/// never comes follows the due one.
struct UnsavedNoticeTimeline<Content: View>: View {
    let history: ClipboardHistory
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.explicit(history.unsavedSince.map { since in
            [since, since + ClipboardHistory.unsavedNoticeDelay, .distantFuture]
        } ?? [])) { timeline in
            content(timeline.date)
        }
    }
}

/// The expanded tab: a search field over the history shown as cards in one row, pinned entries
/// first and newest first within each group, that scrolls sideways past about three cards. Each
/// card shows the start of a text in a fixed-width font, an image's thumbnail or a link in blue,
/// with "<app or kind> · <time ago>" under it. Clicking a card copies it back to `pasteboard`; the
/// keys follow `action(for:fieldHasText:isComposing:area:selection:count:)`. The tab is `width`
/// wide, or as wide as it is offered beyond that (under a wider band, so more cards show), and has a
/// definite height however long the history is. The host adds the margin around it.
struct ClipboardView: View {
    static let width: CGFloat = 360
    static let spacing: CGFloat = 6
    static let searchHeight: CGFloat = 24
    /// Three cards and the start of a fourth fit `width`, so a longer row shows that it scrolls.
    static let cardSize = CGSize(width: 104, height: 70)
    static let cardSpacing: CGFloat = 10
    static let captionGap: CGFloat = 4

    let history: ClipboardHistory
    var pasteboard: NSPasteboard = .general
    @State private var query = ""
    /// The card the arrow keys moved to; nil until the first arrow.
    @State private var selection: ClipItem.ID?
    @FocusState private var focus: Area?

    /// The cards for the entries `visible`: pinned ones first, each group in history order (newest
    /// first).
    static func cards(_ visible: [ClipItem]) -> [ClipItem] {
        visible.filter(\.isPinned) + visible.filter { !$0.isPinned }
    }

    /// Where the keyboard focus is on the screen: the search field or the row of cards.
    enum Area: Hashable {
        case field, cards
    }

    /// A key the screen may take.
    enum Key {
        case left, right, up, down, tab, backTab, enter
    }

    /// What a key does on the screen.
    enum KeyAction: Equatable {
        /// The key goes on to the focused control: the field's caret or an input method.
        case passThrough
        /// Selects the card at the index.
        case select(Int)
        /// Moves the focus into the row of cards and selects the card at the index.
        case enterCards(Int)
        /// Moves the focus back to the search field.
        case focusField
        /// Copies the card at the index.
        case copy(Int)
    }

    /// What `key` does with `count` cards, the card at `selection` selected, the focus in `area`.
    /// ← and → select a card when the field is empty or the focus is in the row, and are the
    /// field's caret otherwise; with no selection they select the first card, at either end they
    /// stay. ↓ or Tab moves from the field into the row, ↑ or Shift-Tab back. Return copies the
    /// selected card, or the first. While an input method composes, as for an unfinished Hangul
    /// syllable, every key goes to the field, as the notch's own keys do.
    static func action(for key: Key, fieldHasText: Bool, isComposing: Bool, area: Area, selection: Int?, count: Int) -> KeyAction {
        guard !isComposing, count > 0 else { return .passThrough }
        switch key {
        case .left, .right:
            guard area == .cards || !fieldHasText else { return .passThrough }
            guard let selection else { return .select(0) }
            return .select(min(max(selection + (key == .left ? -1 : 1), 0), count - 1))
        case .down, .tab:
            return area == .field ? .enterCards(selection ?? 0) : .passThrough
        case .up, .backTab:
            return area == .cards ? .focusField : .passThrough
        case .enter:
            return .copy(selection ?? 0)
        }
    }

    var body: some View {
        UnsavedNoticeTimeline(history: history) { now in
            content(now: now)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            SearchField(query: $query, focus: $focus)
            if history.isStoreUnreadable {
                notice("저장된 기록을 읽지 못했어요. 설정에서 초기화할 수 있어요.")
            }
            if history.showsUnsavedNotice(at: now) {
                notice("기록 \(history.unsavedCount)개는 저장하지 못했어요. 앱을 종료하면 사라져요.")
            }
            let cards = Self.cards(history.matching(query))
            if history.items.isEmpty {
                placeholder("복사한 텍스트, 이미지, 링크가 여기에 쌓여요.")
            } else if cards.isEmpty {
                placeholder("검색어와 맞는 기록이 없어요.")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    strip(cards, now: timeline.date)
                }
            }
        }
        .frame(minWidth: Self.width, idealWidth: Self.width, maxWidth: .infinity, alignment: .leading)
        .onKeyPress(phases: [.down, .repeat]) { press in handle(press) }
    }

    private func strip(_ cards: [ClipItem], now: Date) -> some View {
        let selected = cards.contains { $0.id == selection } ? selection : nil
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Self.cardSpacing) {
                    ForEach(cards) { item in
                        ClipCard(
                            item: item,
                            now: now,
                            isSelected: item.id == selected,
                            copy: { copy(item) },
                            togglePin: { history.setPinned(!item.isPinned, for: item.id) },
                            delete: { history.delete(item.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            // As tall as a card and its caption: a sideways scroll view has no height of its own.
            .fixedSize(horizontal: false, vertical: true)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .cards)
            .onChange(of: selection) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    /// Whether the search field is composing with an input method, as when a Hangul syllable is
    /// not finished: arrows and Return then commit or choose there, as the notch's own keys do.
    private var isComposing: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextInputClient)?.hasMarkedText() == true
    }

    /// The key a press stands for; a press with ⌘, ⌥ or ⌃ is none of them.
    private static func key(_ press: KeyPress) -> Key? {
        guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return nil }
        switch press.key {
        case .leftArrow: return .left
        case .rightArrow: return .right
        case .upArrow: return .up
        case .downArrow: return .down
        case .return: return .enter
        case .tab: return press.modifiers.contains(.shift) ? .backTab : .tab
        // AppKit sends Shift-Tab as the back-tab character.
        case KeyEquivalent("\u{19}"): return .backTab
        default: return nil
        }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard let key = Self.key(press) else { return .ignored }
        let cards = Self.cards(history.matching(query))
        let action = Self.action(
            for: key, fieldHasText: !query.isEmpty, isComposing: isComposing, area: focus == .cards ? .cards : .field,
            selection: cards.firstIndex { $0.id == selection }, count: cards.count
        )
        switch action {
        case .passThrough:
            return .ignored
        case .select(let index):
            selection = cards[index].id
        case .enterCards(let index):
            selection = cards[index].id
            focus = .cards
        case .focusField:
            focus = .field
        case .copy(let index):
            copy(cards[index])
        }
        return .handled
    }

    /// What pressing a card does: puts its entry back on `pasteboard`.
    private func copy(_ item: ClipItem) {
        history.copy(item, to: pasteboard)
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
            .lineLimit(2)
            .padding(.horizontal, 8)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(minWidth: Self.width, idealWidth: Self.width, maxWidth: .infinity)
    }
}

private struct SearchField: View {
    @Binding var query: String
    var focus: FocusState<ClipboardView.Area?>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("기록 검색", text: $query)
                .textFieldStyle(.plain)
                .focused(focus, equals: .field)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("검색어 지우기")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: ClipboardView.searchHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
    }
}

/// One entry as a card: the start of a text in a fixed-width font, a link in blue or an image's
/// thumbnail filling the card, and "<app or kind> · <time ago>" under it. Pin and delete show on
/// hover; a pinned card keeps a pin.
private struct ClipCard: View {
    let item: ClipItem
    let now: Date
    let isSelected: Bool
    let copy: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void
    @State private var isHovered = false

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        let size = ClipboardView.cardSize
        VStack(alignment: .leading, spacing: ClipboardView.captionGap) {
            Button(action: copy) {
                face
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .background(.white.opacity(isHovered ? 0.14 : 0.09))
                    .clipShape(Self.shape)
                    .contentShape(Self.shape)
            }
            .help("눌러서 다시 복사해요")
            .overlay {
                if isSelected {
                    Self.shape.strokeBorder(.white.opacity(0.7), lineWidth: 1.5)
                }
            }
            .overlay(alignment: .topTrailing) {
                controls.padding(5)
            }
            HStack(spacing: 0) {
                Text(item.sourceName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(" · \(relativeTime(from: item.date, to: now))")
                    .fixedSize()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(width: size.width, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("복사", action: copy)
            Button(item.isPinned ? "고정 해제" : "고정", action: togglePin)
            Divider()
            Button("삭제", role: .destructive, action: delete)
        }
    }

    @ViewBuilder private var face: some View {
        switch item.content {
        case .text(let text):
            Text(text.prefix(300).trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(4)
                .padding(8)
        case .link(let url):
            Text(Self.shortURL(url))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.blue)
                .lineLimit(4)
                .padding(8)
        case .image(_, let thumbnail):
            if let image = NSImage(data: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: ClipboardView.cardSize.width, height: ClipboardView.cardSize.height)
                    .clipped()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// Pin and delete while hovered, a pin on a pinned card otherwise.
    @ViewBuilder private var controls: some View {
        if isHovered {
            HStack(spacing: 4) {
                control(item.isPinned ? "pin.fill" : "pin", tint: item.isPinned ? .orange : .white, help: item.isPinned ? "고정 해제" : "고정", action: togglePin)
                control("xmark", tint: .white, help: "삭제", action: delete)
            }
        } else if item.isPinned {
            badge(Image(systemName: "pin.fill").foregroundStyle(.orange))
        }
    }

    private func control(_ symbol: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            badge(Image(systemName: symbol).foregroundStyle(tint))
        }
        .help(help)
    }

    private func badge(_ symbol: some View) -> some View {
        symbol
            .font(.system(size: 9, weight: .semibold))
            .frame(width: 18, height: 18)
            .background(Circle().fill(.black.opacity(0.6)))
    }

    /// The URL without its http or https scheme.
    private static func shortURL(_ url: String) -> String {
        for scheme in ["https://", "http://"] where url.lowercased().hasPrefix(scheme) {
            return String(url.dropFirst(scheme.count))
        }
        return url
    }
}

/// An entry's type: a text or link symbol, or the image's thumbnail filling `size`.
struct ClipIcon: View {
    let item: ClipItem
    let size: CGSize

    var body: some View {
        Group {
            switch item.content {
            case .text:
                Image(systemName: "text.alignleft").foregroundStyle(.secondary)
            case .link:
                Image(systemName: "link").foregroundStyle(.blue)
            case .image(_, let thumbnail):
                if let image = NSImage(data: thumbnail) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

extension ClipItem {
    /// The entry on one line: a text with its runs of spaces and line breaks made single spaces, the
    /// URL of a link, "이미지" for an image.
    var preview: String {
        switch content {
        case .text(let text):
            text.prefix(300).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        case .link(let url):
            url
        case .image:
            "이미지"
        }
    }

    /// The app it was copied from, or its kind when that is not known.
    var sourceName: String {
        if let source { return source.name }
        switch kind {
        case .text: return "텍스트"
        case .link: return "링크"
        case .image: return "이미지"
        }
    }

    /// What a card shows under the entry at `now`: "Terminal · 지금", "이미지 · 2분".
    func caption(at now: Date) -> String {
        "\(sourceName) · \(relativeTime(from: date, to: now))"
    }
}

/// "지금", "5분", "3시간", "2일": whole minutes, hours or days since `date`.
func relativeTime(from date: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "지금"
    case ..<3600: return "\(seconds / 60)분"
    case ..<86400: return "\(seconds / 3600)시간"
    default: return "\(seconds / 86400)일"
    }
}
