import NotchKit
import SwiftUI

/// What a running plugin's page in Settings shows below its header.
struct PluginPage {
    /// nil when the plugin declares none, as every plugin built before SDK 1.4.
    let description: PluginDescription?
    /// Where the declared settings' controls write; the plugin reads and observes the same store.
    let settings: PluginSettings
    let customView: AnyView?
}

/// A part of a declared page below the header, each under its own small title. Every plugin's page
/// has the same parts in the same order; a part with nothing in it is left out, except 권한, which
/// says when the plugin uses none.
enum PluginPagePart: Hashable {
    case summary(String)
    case permissions([PluginPermission])
    case settings([PluginSettingItem])
    /// The plugin's own view, for what the declaration cannot express.
    case custom

    static let noPermissions = "쓰는 권한 없음"

    static func parts(of description: PluginDescription, hasCustomView: Bool) -> [PluginPagePart] {
        var parts: [PluginPagePart] = [.summary(description.summary), .permissions(description.permissions)]
        if !description.settings.isEmpty { parts.append(.settings(description.settings)) }
        if hasCustomView { parts.append(.custom) }
        return parts
    }

    var title: String {
        switch self {
        case .summary: "설명"
        case .permissions: "권한"
        case .settings: "설정"
        case .custom: "추가 설정"
        }
    }
}

/// The declared parts of a plugin's page, one form section each, in `PluginPagePart` order.
struct DeclaredPluginPage: View {
    let description: PluginDescription
    let settings: PluginSettings
    let customView: AnyView?

    var body: some View {
        ForEach(PluginPagePart.parts(of: description, hasCustomView: customView != nil), id: \.self) { part in
            Section {
                switch part {
                case .summary(let summary):
                    Text(summary)
                case .permissions(let permissions) where permissions.isEmpty:
                    Text(PluginPagePart.noPermissions)
                        .foregroundStyle(.secondary)
                case .permissions(let permissions):
                    ForEach(Array(permissions.enumerated()), id: \.offset) { _, permission in
                        PermissionRow(permission: permission)
                    }
                case .settings(let items):
                    ForEach(items) { item in
                        SettingControl(item: item, settings: settings)
                    }
                case .custom:
                    customView
                }
            } header: {
                Text(part.title)
            }
        }
    }
}

private struct PermissionRow: View {
    let permission: PluginPermission

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: permission.kind.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.kind.title)
                Text(permission.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A declared item drawn with the native control of its kind.
private struct SettingControl: View {
    let item: PluginSettingItem
    let settings: PluginSettings

    var body: some View {
        switch item.control {
        case .toggle(let detail, _):
            Toggle(isOn: settings.boolBinding(item)) {
                Text(item.title)
                if let detail { Text(detail) }
            }
        case .choice(let options, _):
            Picker(item.title, selection: settings.stringBinding(item)) {
                ForEach(options, id: \.value) { option in
                    Text(option.title).tag(option.value)
                }
            }
        case .number(let range, let step, let unit, _):
            let value = settings.numberBinding(item)
            LabeledContent(item.title) {
                HStack(spacing: 6) {
                    Text(NumberSettingText.text(value.wrappedValue, step: step, unit: unit))
                        .monospacedDigit()
                    Stepper(item.title, value: value, in: range, step: step)
                        .labelsHidden()
                }
            }
        case .text(let placeholder, _):
            TextField(item.title, text: settings.stringBinding(item), prompt: Text(placeholder))
        @unknown default:
            EmptyView()
        }
    }
}

/// How a number item shows its value next to its stepper: with as many decimals as its step or the
/// value itself has, whichever is more, so two values the stepper reaches never read the same and a
/// value off the step grid keeps its fraction, then its unit.
enum NumberSettingText {
    /// A step or value with more decimals, or endless ones such as 1/3, shows this many.
    static let maxFractionDigits = 6

    static func text(_ value: Double, step: Double, unit: String?, locale: Locale = .autoupdatingCurrent) -> String {
        let digits = max(fractionDigits(of: step), fractionDigits(of: value))
        return value.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + (unit ?? "")
    }

    /// The decimal places of `number`: the fewest that make it a whole number, within the error of a
    /// binary `Double` such as 0.1.
    static func fractionDigits(of number: Double) -> Int {
        var scaled = abs(number)
        for digits in 0..<maxFractionDigits {
            if abs(scaled - scaled.rounded()) <= 1e-9 * max(1, scaled) { return digits }
            scaled *= 10
        }
        return maxFractionDigits
    }
}

extension PluginSettings {
    /// The bindings the page's controls write through: the plugin's store, which tells the plugin.
    func boolBinding(_ item: PluginSettingItem) -> Binding<Bool> {
        Binding(get: { self.bool(item) }, set: { self.set($0, for: item) })
    }

    func numberBinding(_ item: PluginSettingItem) -> Binding<Double> {
        Binding(get: { self.number(item) }, set: { self.set($0, for: item) })
    }

    func stringBinding(_ item: PluginSettingItem) -> Binding<String> {
        Binding(get: { self.string(item) }, set: { self.set($0, for: item) })
    }
}

extension PluginPermission.Kind {
    var symbol: String {
        switch self {
        case .accessibility: "accessibility"
        case .automation: "applescript"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        case .notifications: "bell.badge"
        case .files: "folder"
        case .keychain: "key"
        case .network: "network"
        case .helperProcesses: "terminal"
        case .otherAppSettings: "slider.horizontal.3"
        case .pasteboard: "doc.on.clipboard"
        @unknown default: "questionmark.circle"
        }
    }

    /// The name macOS gives the permission, or what the resource is, with the app or path it names.
    var title: String {
        switch self {
        case .accessibility: "손쉬운 사용"
        case .automation(let app): "자동화: \(app)"
        case .screenRecording: "화면 기록"
        case .bluetooth: "블루투스"
        case .notifications: "알림"
        case .files(let path): "파일: \(path)"
        case .keychain: "키체인"
        case .network: "네트워크"
        case .helperProcesses: "도우미 프로그램 실행"
        case .otherAppSettings(let app): "\(app) 설정 변경"
        case .pasteboard: "클립보드"
        @unknown default: "알 수 없는 권한"
        }
    }
}
