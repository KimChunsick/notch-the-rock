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
/// with "<app or kind> · <time ago>" under it. Clicking a card copies it back to `pasteboard`;
/// ← and → move a selection between the cards and Return copies the selected one, or the first.
/// The tab is `width` wide and has a definite height however long the history is. The host adds
/// the margin around it.
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

    /// The cards for the entries `visible`: pinned ones first, each group in history order (newest
    /// first).
    static func cards(_ visible: [ClipItem]) -> [ClipItem] {
        visible.filter(\.isPinned) + visible.filter { !$0.isPinned }
    }

    /// The card an arrow moves the selection to, `offset` cards along `ids`. With no selection, or
    /// one no longer among `ids`, any arrow selects the first card; at either end it stays.
    static func selection(from current: ClipItem.ID?, moving offset: Int, in ids: [ClipItem.ID]) -> ClipItem.ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else { return ids[0] }
        return ids[min(max(index + offset, 0), ids.count - 1)]
    }

    var body: some View {
        UnsavedNoticeTimeline(history: history) { now in
            content(now: now)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            SearchField(query: $query)
            if history.isStoreUnreadable {
                notice("저장된 기록을 읽지 못했어요. 설정에서 초기화할 수 있어요.")
            }
            if history.showsUnsavedNotice(at: now) {
                notice("기록 \(history.unsavedCount)개는 저장하지 못했어요. 앱을 종료하거나 클립보드 기능을 끄면 사라져요.")
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
        .frame(width: Self.width)
        .onKeyPress(.leftArrow) { moveSelection(by: -1) }
        .onKeyPress(.rightArrow) { moveSelection(by: 1) }
        .onKeyPress(.return) { copySelection() }
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

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let ids = Self.cards(history.matching(query)).map(\.id)
        guard !ids.isEmpty, !isComposing else { return .ignored }
        selection = Self.selection(from: selection, moving: offset, in: ids)
        return .handled
    }

    private func copySelection() -> KeyPress.Result {
        let cards = Self.cards(history.matching(query))
        guard !isComposing, let item = cards.first(where: { $0.id == selection }) ?? cards.first else { return .ignored }
        copy(item)
        return .handled
    }

    /// What pressing a card does: puts its entry back on `pasteboard`.
    func copy(_ item: ClipItem) {
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
            .frame(width: Self.width)
    }
}

private struct SearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("기록 검색", text: $query)
                .textFieldStyle(.plain)
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

/// The plugin's section in Settings: how many entries are kept and a button that deletes every
/// unpinned one. When the stored history cannot be read, a second row offers to reset it.
struct ClipboardSettingsView: View {
    let history: ClipboardHistory
    @State private var isConfirmingClear = false
    @State private var isConfirmingReset = false

    var body: some View {
        let pinned = history.items.filter(\.isPinned).count
        let unpinned = history.items.count - pinned
        LabeledContent {
            Button("기록 지우기", role: .destructive) {
                isConfirmingClear = true
            }
            .disabled(unpinned == 0)
            .confirmationDialog("고정하지 않은 기록 \(unpinned)개를 지울까요?", isPresented: $isConfirmingClear) {
                Button("지우기", role: .destructive) { history.clearUnpinned() }
            } message: {
                Text("고정한 기록은 남아요.")
            }
        } label: {
            Text("클립보드 기록 \(history.items.count)개")
            Text("고정 \(pinned)개는 지우지 않아요. 고정하지 않은 기록은 최근 \(ClipboardHistory.unpinnedLimit)개까지 둬요.")
        }
        if history.isStoreUnreadable {
            LabeledContent {
                Button("초기화", role: .destructive) {
                    isConfirmingReset = true
                }
                .confirmationDialog("디스크에 있는 읽지 못한 기록을 지울까요?", isPresented: $isConfirmingReset) {
                    Button("지우고 새로 저장", role: .destructive) { history.resetUnreadableStore() }
                } message: {
                    Text("디스크에 저장돼 있던, 읽지 못한 기록만 지워요. 지운 기록은 되살릴 수 없어요. 지금 목록에 보이는 기록은 그대로 두고, 지운 뒤에 다시 저장해요.")
                }
            } label: {
                Text("저장된 기록을 읽지 못했어요")
                Text("지금은 기록을 저장하지 않아서 앱을 종료하거나 클립보드 기능을 끄면 사라져요. 초기화하면 다시 저장해요.")
            }
        }
    }
}
