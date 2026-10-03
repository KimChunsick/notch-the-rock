import SwiftUI

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
                    Button("지우고 새로 저장", role: .destructive) { Task { await history.resetUnreadableStore() } }
                } message: {
                    Text("디스크에 저장돼 있던, 읽지 못한 기록만 지워요. 지운 기록은 되살릴 수 없어요. 지금 목록에 보이는 기록은 그대로 두고, 지운 뒤에 다시 저장해요.")
                }
            } label: {
                Text("저장된 기록을 읽지 못했어요")
                Text("지금은 기록을 저장하지 않아서 앱을 종료하면 사라져요. 초기화하면 다시 저장해요.")
            }
        }
    }
}
