import AppKit
import SwiftUI

/// Settings: every project found or added, with its state and a button to remove it, and a folder
/// picker to add one.
struct DStackSettingsView: View {
    let model: DStackModel

    var body: some View {
        LabeledContent {
            Button("폴더 추가…") { chooseFolder() }
        } label: {
            Text("D-STACK 프로젝트")
            Text("다른 폴더는 직접 더하고, 보고 싶지 않은 프로젝트는 빼요.")
        }
        .onAppear { Task { await model.refresh() } }
        ForEach(model.projects) { project in
            LabeledContent {
                Button("빼기") { Task { await model.remove(project.url) } }
            } label: {
                Text(project.name)
                Text("\((project.url.path as NSString).abbreviatingWithTildeInPath) · \(state(project))")
            }
        }
    }

    private func state(_ project: DStackModel.Project) -> String {
        switch project.reading {
        case .open(let run): "열린 실행: \(run.title)"
        case .unsupported(let reason): "형식을 읽지 못했어요 · \(reason)"
        case .noOpenRun: project.hasStore ? "열린 실행이 없어요" : "D-STACK 저장소가 없어요"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "추가"
        panel.message = "D-STACK을 쓰는 프로젝트 폴더를 골라 주세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.add(url) }
    }
}
