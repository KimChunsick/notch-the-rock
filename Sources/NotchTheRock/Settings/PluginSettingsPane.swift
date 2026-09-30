import AppKit
import SwiftUI

/// 플러그인: every discovered bundle with its state, an on/off switch, consent for user bundles and
/// the plugin's own settings page while it is on.
struct PluginSettingsPane: View {
    let catalog: PluginCatalog
    @State private var consentFailures: [PluginRecord.ID: String] = [:]
    @State private var folderFailure: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if catalog.records.isEmpty {
                    Text("찾은 플러그인이 없어요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(catalog.records) { record in
                    Section {
                        PluginRow(
                            record: record,
                            consentFailure: consentFailures[record.id],
                            setEnabled: { catalog.setEnabled($0, for: record.id) },
                            consent: { consent(to: record.id) }
                        )
                        if let settings = catalog.settingsView(for: record.id) {
                            settings
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                if let folderFailure {
                    Text(folderFailure)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("플러그인 폴더 열기") { openUserFolder() }
                Button("다시 불러오기") {
                    consentFailures = [:]
                    catalog.reload()
                }
            }
            .padding([.horizontal, .bottom])
        }
    }

    private func consent(to id: PluginRecord.ID) {
        do {
            try catalog.consent(to: id)
            consentFailures[id] = nil
        } catch {
            consentFailures[id] = "\(error)"
        }
    }

    private func openUserFolder() {
        let folder = catalog.locations.user
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folderFailure = nil
            NSWorkspace.shared.open(folder)
        } catch {
            folderFailure = "플러그인 폴더를 만들지 못했어요: \(error.localizedDescription)"
        }
    }
}

private struct PluginRow: View {
    let record: PluginRecord
    let consentFailure: String?
    let setEnabled: (Bool) -> Void
    let consent: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name)
                    .font(.headline)
                Text("\(record.version) · \(record.source.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(record.stateText)
                    .font(.caption)
                    .foregroundStyle(stateColor)
                    .textSelection(.enabled)
                if let consentFailure {
                    Text(consentFailure)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if case .needsConsent = record.state, record.source == .user {
                Button("허락") { consent() }
            }
            Toggle("켜기", isOn: Binding(get: { record.state == .on }, set: { setEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!record.canToggle)
        }
    }

    private var stateColor: Color {
        switch record.state {
        case .on, .off: record.needsRestart ? .orange : .secondary
        case .needsConsent: .orange
        case .failed: .red
        }
    }
}

extension PluginRecord {
    static let restartNotice = "앱을 다시 켜야 적용돼요"

    /// 켜짐 / 꺼짐 / 허락 필요 / 오류, with the reason and a relaunch notice when there is one.
    var stateText: String {
        let text = switch state {
        case .on: "켜짐"
        case .off: "꺼짐"
        case .needsConsent(let reason): "허락 필요: \(reason)"
        case .failed(let reason): "오류: \(reason)"
        }
        return needsRestart ? "\(text) · \(Self.restartNotice)" : text
    }

    /// Only a loaded or loadable plugin can be switched; consent and errors are resolved first.
    var canToggle: Bool { state == .on || state == .off }
}

extension PluginRecord.Source {
    var label: String {
        switch self {
        case .builtIn: "내장"
        case .user: "사용자"
        }
    }
}
