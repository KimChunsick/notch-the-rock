import NotchKit
import SwiftUI

/// The home tile; tapping it opens the tab. Wide: the three most recently copied entries, a line
/// each with the type icon and a pin on pinned ones. Small: the newest entry's icon and a short
/// preview over the number of entries. Both mark a history kept in memory only when the tab shows
/// one of its notices about it.
struct ClipboardTile: View {
    static let wideCount = 3

    let history: ClipboardHistory
    let size: TileSize

    /// The entries the tile shows, most recently copied first: three when wide, one when small.
    var entries: [ClipItem] {
        Array(history.items.prefix(size == .small ? 1 : Self.wideCount))
    }

    /// Whether the tile marks the history as kept in memory only at `date`: the stored history could
    /// not be read, or the unsaved notice is due.
    func showsWarning(at date: Date) -> Bool {
        history.isStoreUnreadable || history.showsUnsavedNotice(at: date)
    }

    var body: some View {
        UnsavedNoticeTimeline(history: history) { now in
            let warns = showsWarning(at: now)
            switch size {
            case .small:
                small
                    .overlay(alignment: .topTrailing) {
                        if warns { warning }
                    }
            case .wide, .large:
                wide(warns: warns)
            @unknown default:
                wide(warns: warns)
            }
        }
    }

    private var warning: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
            .help(history.isStoreUnreadable ? "저장된 기록을 읽지 못했어요." : "기록 \(history.unsavedCount)개는 저장하지 못했어요.")
    }

    /// 170 pt of rows, the warning taking room beside them.
    private func wide(warns: Bool) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 5) {
                if entries.isEmpty {
                    Label("복사한 기록이 없어요.", systemImage: "doc.on.clipboard")
                        .foregroundStyle(.secondary)
                        .frame(height: 18)
                }
                ForEach(entries) { item in
                    HStack(spacing: 6) {
                        ClipIcon(item: item, size: CGSize(width: 20, height: 15))
                        Text(item.preview)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        if item.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                    .frame(height: 18)
                }
            }
            .frame(width: warns ? 154 : 170, alignment: .leading)
            if warns { warning.frame(width: 12) }
        }
        .font(.system(size: 11))
        .padding(10)
    }

    /// 70 pt wide: the icon, two lines of preview and the count.
    private var small: some View {
        VStack(spacing: 4) {
            if let item = entries.first {
                ClipIcon(item: item, size: CGSize(width: 34, height: 24))
                    .font(.system(size: 18))
                Text(item.preview)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(height: 24)
                Text("비어 있어요")
                    .foregroundStyle(.secondary)
            }
            Text("\(history.items.count)개")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .frame(width: 70)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
