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

/// The expanded tab: a search field over the history, pinned entries first, newest first within
/// each group. Clicking a row copies it back to the general pasteboard. It is `width` wide and the
/// list `listHeight` tall, scrolling past that, so the tab has the same definite size however long
/// the history is.
struct ClipboardView: View {
    static let width: CGFloat = 360
    static let listHeight: CGFloat = 180

    let history: ClipboardHistory
    @State private var query = ""

    var body: some View {
        UnsavedNoticeTimeline(history: history) { now in
            content(now: now)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SearchField(query: $query)
            if history.isStoreUnreadable {
                notice("저장된 기록을 읽지 못했어요. 설정에서 초기화할 수 있어요.")
            }
            if history.showsUnsavedNotice(at: now) {
                notice("기록 \(history.unsavedCount)개는 저장하지 못했어요. 앱을 종료하거나 클립보드 기능을 끄면 사라져요.")
            }
            let visible = history.matching(query)
            if history.items.isEmpty {
                placeholder("복사한 텍스트, 이미지, 링크가 여기에 쌓여요.")
            } else if visible.isEmpty {
                placeholder("검색어와 맞는 기록이 없어요.")
            } else {
                TimelineView(.periodic(from: .now, by: 30)) { timeline in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            let pinned = visible.filter(\.isPinned)
                            let recent = visible.filter { !$0.isPinned }
                            if !pinned.isEmpty {
                                header("고정됨")
                                rows(pinned, now: timeline.date)
                                if !recent.isEmpty { header("최근") }
                            }
                            rows(recent, now: timeline.date)
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: Self.listHeight)
                }
            }
        }
        .frame(width: Self.width)
    }

    private func rows(_ items: [ClipItem], now: Date) -> some View {
        ForEach(items) { item in
            ClipRow(
                item: item,
                now: now,
                copy: { history.copy(item, to: .general) },
                togglePin: { history.setPinned(!item.isPinned, for: item.id) },
                delete: { history.delete(item.id) }
            )
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
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
            .frame(width: Self.width, height: Self.listHeight)
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
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.1)))
    }
}

private struct ClipRow: View {
    let item: ClipItem
    let now: Date
    let copy: () -> Void
    let togglePin: () -> Void
    let delete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Button(action: copy) {
                HStack(spacing: 8) {
                    ClipIcon(item: item, size: CGSize(width: 26, height: 20))
                    Text(item.preview)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(relativeTime(from: item.date, to: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .help("눌러서 다시 복사해요")
            Button(action: togglePin) {
                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(item.isPinned ? Color.orange : Color.secondary)
            }
            .help(item.isPinned ? "고정 해제" : "고정")
            Button(action: delete) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .help("삭제")
            .opacity(isHovered ? 1 : 0)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(isHovered ? 0.1 : 0)))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("복사", action: copy)
            Button(item.isPinned ? "고정 해제" : "고정", action: togglePin)
            Divider()
            Button("삭제", role: .destructive, action: delete)
        }
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
}

/// "방금", "5분 전", "3시간 전", "2일 전".
func relativeTime(from date: Date, to now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "방금"
    case ..<3600: return "\(seconds / 60)분 전"
    case ..<86400: return "\(seconds / 3600)시간 전"
    default: return "\(seconds / 86400)일 전"
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
