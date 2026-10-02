import Foundation
import Testing
@testable import NotchKit

@MainActor
@Suite struct PluginDescriptionTests {
    static let toggle = PluginSettingItem.toggle(key: "showsSeconds", title: "초 보이기", detail: "시계에 초를 보여줘요.", default: true)
    static let choice = PluginSettingItem.choice(key: "style", title: "모양", options: [
        PluginSettingOption("digital", title: "숫자"),
        PluginSettingOption("analog", title: "바늘"),
    ], default: "digital")
    static let number = PluginSettingItem.number(key: "interval", title: "새로 고침 간격", range: 1...60, step: 1, unit: "초", default: 5)
    static let text = PluginSettingItem.text(key: "label", title: "이름표", placeholder: "비워 두면 이름이 없어요", default: "")

    /// A store over a defaults suite named by a temporary path, removed afterwards.
    private func withSettings(_ body: (PluginSettings, UserDefaults) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PluginDescriptionTests-\(UUID().uuidString)")
        let suite = directory.appendingPathComponent("defaults").path
        defer {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let storage = try PluginStorage(directory: directory, defaultsSuiteName: suite, keychainService: "PluginDescriptionTests")
        let context = NotchContext(pluginID: "com.example.described", bundleURL: directory, host: RecordingHost(), storage: storage)
        try await body(context.settings, storage.defaults)
    }

    @Test func R48__sdk_1_4_adds_the_description_and_a_plugin_without_one_reads_nil() throws {
        #expect(NotchKitSDK.version == SDKVersion(major: 1, minor: 4))
        #expect(NotchKitSDK.version.supports(SDKVersion(major: 1, minor: 3)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PluginDescriptionTests-\(UUID().uuidString)")
        let suite = directory.appendingPathComponent("defaults").path
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try PluginStorage(directory: directory, defaultsSuiteName: suite, keychainService: "PluginDescriptionTests")
        let context = NotchContext(pluginID: SamplePlugin.manifest.id, bundleURL: directory, host: RecordingHost(), storage: storage)
        #expect(SamplePlugin(context: context).pluginDescription == nil)
    }

    @Test func R48__declared_settings_read_their_defaults_until_set() async throws {
        try await withSettings { settings, _ in
            #expect(settings.bool(Self.toggle) == true)
            #expect(settings.string(Self.choice) == "digital")
            #expect(settings.number(Self.number) == 5)
            #expect(settings.string(Self.text) == "")
        }
    }

    @Test func R48__set_persists_to_the_plugin_defaults_and_reaches_every_observer() async throws {
        try await withSettings { settings, defaults in
            let first = settings.changes()
            let second = settings.changes()
            settings.set(false, for: Self.toggle)
            settings.set("analog", for: Self.choice)
            settings.set(30, for: Self.number)
            settings.set("거실", for: Self.text)
            #expect(defaults.object(forKey: "showsSeconds") as? Bool == false)
            #expect(defaults.object(forKey: "style") as? String == "analog")
            #expect(defaults.object(forKey: "interval") as? Double == 30)
            #expect(defaults.object(forKey: "label") as? String == "거실")
            #expect(settings.bool(Self.toggle) == false)
            #expect(settings.string(Self.choice) == "analog")
            #expect(settings.number(Self.number) == 30)
            #expect(settings.string(Self.text) == "거실")
            for stream in [first, second] {
                var keys: [String] = []
                for await key in stream {
                    keys.append(key)
                    if keys.count == 4 { break }
                }
                #expect(keys == ["showsSeconds", "style", "interval", "label"])
            }
        }
    }

    @Test func R48__values_the_declaration_does_not_allow_are_refused_or_read_as_the_default() async throws {
        try await withSettings { settings, defaults in
            settings.set("square", for: Self.choice)
            settings.set(true, for: Self.number)
            #expect(defaults.object(forKey: "style") == nil, "not one of the options")
            #expect(defaults.object(forKey: "interval") == nil, "a switch value for a number item")
            settings.set(500, for: Self.number)
            #expect(settings.number(Self.number) == 60, "kept inside the range")
            defaults.set("square", forKey: "style")
            defaults.set(-3, forKey: "interval")
            defaults.set("yes", forKey: "showsSeconds")
            #expect(settings.string(Self.choice) == "digital")
            #expect(settings.number(Self.number) == 5)
            #expect(settings.bool(Self.toggle) == true)
        }
    }
}
