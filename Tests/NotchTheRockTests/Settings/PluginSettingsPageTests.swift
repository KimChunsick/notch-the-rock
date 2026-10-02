import AppKit
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// A plugin declaring a summary, two permissions and one item of each kind, with a view of its own.
/// It records every change its settings stream delivers, with the value it then reads.
@MainActor
private final class DeclaringPlugin: NotchPlugin {
    static let manifest = PluginManifest(id: "com.example.declaring", name: "Declaring", version: "1.0.0", symbol: "gearshape", sdkVersion: NotchKitSDK.version)
    static let toggle = PluginSettingItem.toggle(key: "showsSeconds", title: "초 보이기", detail: "시계에 초를 함께 보여줘요.", default: true)
    static let choice = PluginSettingItem.choice(key: "style", title: "시계 모양", options: [
        PluginSettingOption("digital", title: "숫자"),
        PluginSettingOption("analog", title: "바늘"),
    ], default: "digital")
    static let number = PluginSettingItem.number(key: "interval", title: "새로 고침 간격", range: 1...60, step: 1, unit: "초", default: 5)
    static let text = PluginSettingItem.text(key: "label", title: "이름표", placeholder: "비워 두면 이름이 없어요", default: "")
    static let description = PluginDescription(
        summary: "접힌 노치 옆에 지금 시각을 보여줘요.",
        permissions: [
            PluginPermission(.accessibility, reason: "단축키로 시계를 열 때 써요."),
            PluginPermission(.files(path: "~/Library/Calendars"), reason: "다음 일정을 시계 옆에 보여줘요."),
        ],
        settings: [toggle, choice, number, text]
    )
    static var instances: [String: DeclaringPlugin] = [:]

    let context: NotchContext
    /// Each delivered key with the value read right after it.
    var observed: [String: String] = [:]
    private var watching: Task<Void, Never>?

    init(context: NotchContext) {
        self.context = context
        Self.instances[context.pluginID] = self
    }

    func activate() {
        let changes = context.settings.changes()
        watching = Task { [weak self] in
            for await key in changes { self?.record(key) }
        }
    }

    func deactivate() {
        watching?.cancel()
    }

    private func record(_ key: String) {
        let settings = context.settings
        observed[key] = switch key {
        case Self.toggle.key: "\(settings.bool(Self.toggle))"
        case Self.number.key: "\(settings.number(Self.number))"
        case Self.choice.key: settings.string(Self.choice)
        default: settings.string(Self.text)
        }
    }

    var pluginDescription: PluginDescription? { Self.description }
    var settingsView: AnyView? { AnyView(Button("계정 연결") {}) }
}

/// Declares settings items and draws no view of its own.
@MainActor
private final class DeclaredOnlyPlugin: NotchPlugin {
    static let manifest = PluginManifest(id: "com.example.declared", name: "Declared", version: "1.0.0", symbol: "gearshape", sdkVersion: NotchKitSDK.version)
    init(context: NotchContext) {}
    func activate() {}
    func deactivate() {}
    var pluginDescription: PluginDescription? { DeclaringPlugin.description }
}

/// Built against SDK 1.3: no description, only its own view.
@MainActor
private final class LegacyPlugin: NotchPlugin {
    static let manifest = PluginManifest(id: "com.example.legacy", name: "Legacy", version: "1.0.0", symbol: "clock", sdkVersion: SDKVersion(major: 1, minor: 3))
    init(context: NotchContext) {}
    func activate() {}
    func deactivate() {}
    var settingsView: AnyView? { AnyView(Text("예전 방식으로 그린 설정이에요.")) }
}

@MainActor
@Suite struct PluginSettingsPageTests {
    /// A catalog with one built-in bundle opened as `type`, and that bundle's record id.
    private func load(_ type: any NotchPlugin.Type, fixture: PluginFixture) throws -> (catalog: PluginCatalog, record: PluginRecord.ID, pluginID: String) {
        let id = fixture.newIdentifier()
        let bundle = try fixture.makeBundle(in: fixture.locations.builtIn!, name: "Page", identifier: id, sdk: type.manifest.sdkVersion.description)
        let catalog = fixture.catalog(open: { info in
            let manifest = type.manifest
            return (PluginManifest(id: info.identifier, name: manifest.name, version: manifest.version, symbol: manifest.symbol, sdkVersion: manifest.sdkVersion), type)
        })
        catalog.loadAll()
        return (catalog, bundle.path, id)
    }

    @Test func R48__the_page_shows_summary_then_permissions_then_settings_then_the_plugins_own_view() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let (catalog, record, _) = try load(DeclaringPlugin.self, fixture: fixture)
        let page = try #require(catalog.page(for: record))
        let description = try #require(page.description)
        let parts = PluginPagePart.parts(of: description, hasCustomView: page.customView != nil)
        #expect(parts == [
            .summary("접힌 노치 옆에 지금 시각을 보여줘요."),
            .permissions(DeclaringPlugin.description.permissions),
            .settings(DeclaringPlugin.description.settings),
            .custom,
        ])
        #expect(parts.map(\.title) == ["설명", "권한", "설정", "추가 설정"])
        #expect(PluginPermission.Kind.accessibility.title == "손쉬운 사용")
        #expect(PluginPermission.Kind.files(path: "~/Library/Calendars").title == "파일: ~/Library/Calendars")
        let none = PluginPagePart.parts(of: PluginDescription(summary: "요약", permissions: []), hasCustomView: false)
        #expect(none == [.summary("요약"), .permissions([])], "no settings and no own view: those parts are left out")
        #expect(PluginPagePart.noPermissions == "쓰는 권한 없음")
        catalog.setEnabled(false, for: record)
        #expect(catalog.page(for: record) == nil, "a plugin that is off shows only its header")
    }

    @Test func R48__changing_each_control_saves_to_the_plugin_storage_and_reaches_the_plugin() async throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let (catalog, record, pluginID) = try load(DeclaringPlugin.self, fixture: fixture)
        let page = try #require(catalog.page(for: record))
        let settings = page.settings
        settings.boolBinding(DeclaringPlugin.toggle).wrappedValue = false
        settings.stringBinding(DeclaringPlugin.choice).wrappedValue = "analog"
        settings.numberBinding(DeclaringPlugin.number).wrappedValue = 12
        settings.stringBinding(DeclaringPlugin.text).wrappedValue = "거실"

        let suite = try #require(UserDefaults(suiteName: "\(fixture.locations.storagePrefix).\(PluginKey(pluginID).rawValue)"))
        #expect(suite.object(forKey: "showsSeconds") as? Bool == false)
        #expect(suite.object(forKey: "style") as? String == "analog")
        #expect(suite.object(forKey: "interval") as? Double == 12)
        #expect(suite.object(forKey: "label") as? String == "거실")

        let plugin = try #require(DeclaringPlugin.instances[pluginID])
        let deadline = ContinuousClock.now + .seconds(5)
        while plugin.observed.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(plugin.observed == ["showsSeconds": "false", "style": "analog", "interval": "12.0", "label": "거실"])
    }

    @Test func R48__declared_settings_alone_give_the_plugin_a_settings_page_in_the_home() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let host = NotchHostModel()
        let id = fixture.newIdentifier()
        try fixture.makeBundle(in: fixture.locations.builtIn!, name: "Declared", identifier: id, sdk: NotchKitSDK.version.description)
        let catalog = fixture.catalog(host: host, open: { info in
            (PluginManifest(id: info.identifier, name: "Declared", version: "1.0.0", symbol: "gearshape", sdkVersion: NotchKitSDK.version), DeclaredOnlyPlugin.self)
        })
        catalog.loadAll()
        #expect(host.plugins.first { $0.pluginID == id }?.hasSettings == true)
    }

    @Test func R48__a_plugin_built_before_1_4_shows_only_its_header_and_its_own_view() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let (catalog, record, _) = try load(LegacyPlugin.self, fixture: fixture)
        let page = try #require(catalog.page(for: record))
        #expect(page.description == nil)
        #expect(page.customView != nil)
    }

    @Test func R48__every_permission_kind_has_a_symbol_and_a_korean_name() {
        let kinds: [PluginPermission.Kind] = [
            .accessibility, .automation(app: "터미널"), .screenRecording, .bluetooth, .notifications,
            .files(path: "~/Documents"), .keychain, .network, .helperProcesses, .otherAppSettings(app: "Claude Code"), .pasteboard,
        ]
        for kind in kinds {
            #expect(NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil) != nil, "\(kind.symbol)")
            #expect(!kind.title.isEmpty)
        }
    }

    // MARK: Renders

    /// The declaring plugin's page and the 1.3 plugin's page. Written only when
    /// NOTCH_SETTINGS_CAPTURE_DIR is set.
    @Test func R48__renders_of_the_settings_page() throws {
        guard let directory = ProcessInfo.processInfo.environment["NOTCH_SETTINGS_CAPTURE_DIR"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let pages: [(any NotchPlugin.Type, CGFloat, String)] = [
            (DeclaringPlugin.self, 900, "R48-render-settings-T142.png"),
            (LegacyPlugin.self, 320, "R48-render-settings-legacy-T142.png"),
        ]
        for (type, height, name) in pages {
            let fixture = try PluginFixture()
            defer { fixture.cleanUp() }
            let (catalog, _, _) = try load(type, fixture: fixture)
            try Self.render(PluginSettingsPane(catalog: catalog), height: height, to: folder.appendingPathComponent(name))
        }
    }

    static func render(_ view: some View, height: CGFloat, to url: URL) throws {
        let hosting = NSHostingView(rootView: view.frame(width: 560, height: height).background(Color(white: 0.12)).environment(\.colorScheme, .dark))
        hosting.frame = CGRect(x: 0, y: 0, width: 560, height: height)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: .now + 0.1)
        }
        let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
