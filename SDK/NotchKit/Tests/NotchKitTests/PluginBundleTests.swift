import Foundation
import Testing
@testable import NotchKit

/// Writes `<name>.notchplugin/Contents/Info.plist` (no executable) into a fresh temporary folder.
func makeBundle(name: String = "Sample", info: [String: Any]) throws -> URL {
    let bundle = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
        .appendingPathComponent("\(name).notchplugin")
    let contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: contents.appendingPathComponent("Info.plist"))
    return bundle
}

@MainActor
@Suite struct PluginBundleTests {
    let validInfo: [String: Any] = [
        "CFBundleIdentifier": "com.example.sample",
        "CFBundleExecutable": "Sample",
        "NotchKitSDKVersion": "1.0",
        "NotchPluginEntry": "notchkit_plugin_entry",
    ]

    @Test func R03__bundle_info_reads_declared_keys_without_running_code() throws {
        let bundle = try makeBundle(info: validInfo)
        let info = try PluginBundleInfo(contentsOf: bundle)
        #expect(info.identifier == "com.example.sample")
        #expect(info.sdkVersion == SDKVersion(major: 1, minor: 0))
        #expect(info.entrySymbol == "notchkit_plugin_entry")
        #expect(info.executableURL.path.hasSuffix("Sample.notchplugin/Contents/MacOS/Sample"))
    }

    @Test func R03__loader_rejects_wrong_major_before_opening_the_binary() throws {
        var plist = validInfo
        plist["NotchKitSDKVersion"] = "2.0"
        let bundle = try makeBundle(info: plist)
        let info = try PluginBundleInfo(contentsOf: bundle)
        // The bundle has no executable: reaching dlopen would fail with a different error.
        #expect(throws: PluginLoadError.incompatibleSDK(required: SDKVersion(major: 2, minor: 0), host: NotchKitSDK.version)) {
            try PluginLoader.load(info)
        }
    }

    @Test func R03__bundle_info_reports_missing_and_malformed_keys() throws {
        var missing = validInfo
        missing.removeValue(forKey: "NotchKitSDKVersion")
        #expect(throws: PluginLoadError.missingKey("NotchKitSDKVersion")) {
            try PluginBundleInfo(contentsOf: try makeBundle(info: missing))
        }
        var malformed = validInfo
        malformed["NotchKitSDKVersion"] = "one"
        #expect(throws: PluginLoadError.malformedSDKVersion("one")) {
            try PluginBundleInfo(contentsOf: try makeBundle(info: malformed))
        }
        let notBundle = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitTests-\(UUID().uuidString)")
        #expect(throws: PluginLoadError.notABundle(notBundle)) {
            try PluginBundleInfo(contentsOf: notBundle)
        }
    }

    @Test func R03__entry_symbol_defaults_when_key_is_absent() throws {
        var plist = validInfo
        plist.removeValue(forKey: "NotchPluginEntry")
        let info = try PluginBundleInfo(contentsOf: try makeBundle(info: plist))
        #expect(info.entrySymbol == NotchPluginEntry.defaultSymbol)
        #expect(NotchPluginEntry.defaultSymbol == "notchkit_plugin_entry")
    }
}
