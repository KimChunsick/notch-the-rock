import SwiftUI
import Testing
@testable import NotchKit

@MainActor
private final class NoSetupPlugin: NotchPlugin {
    static let manifest = PluginManifest(id: "com.example.plain", name: "Plain", version: "1.0.0", symbol: "circle", sdkVersion: NotchKitSDK.version)
    init(context: NotchContext) {}
    func activate() {}
    func deactivate() {}
}

@MainActor
@Suite struct PluginSetupTests {
    @Test func R43__sdk_1_3_adds_the_setup_step_and_a_plugin_without_one_reads_nil() throws {
        #expect(NotchKitSDK.version >= SDKVersion(major: 1, minor: 3))
        #expect(NotchKitSDK.version.supports(SDKVersion(major: 1, minor: 2)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PluginSetupTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try PluginStorage(directory: directory, defaultsSuiteName: directory.appendingPathComponent("defaults").path, keychainService: "PluginSetupTests")
        let context = NotchContext(pluginID: NoSetupPlugin.manifest.id, bundleURL: directory, host: RecordingHost(), storage: storage)
        #expect(NoSetupPlugin(context: context).setup == nil)
    }

    @Test func R43__an_item_reads_its_state_and_performs_only_when_asked() {
        var state = PluginSetupState.notConnected
        var performed = 0
        let item = PluginSetupItem(id: "tool", title: "Tool", detail: "연결해요", state: { state }, perform: {
            performed += 1
            state = .connected
        })
        #expect(item.state == .notConnected)
        #expect(performed == 0)
        item.perform()
        #expect(performed == 1)
        #expect(item.state == .connected)
        #expect(PluginSetup(title: "연결", message: "", items: []) == nil, "no items, no step")
        #expect(PluginSetup(title: "연결", message: "", items: [item])?.items.map(\.id) == ["tool"])
    }
}
