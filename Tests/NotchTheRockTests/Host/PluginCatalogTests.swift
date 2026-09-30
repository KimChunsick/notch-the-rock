import Darwin
import Foundation
import NotchKit
import SwiftUI
import Testing
@testable import NotchTheRock

/// Temporary plugin folders, an isolated defaults suite and helpers to write bundles into them.
@MainActor
final class PluginFixture {
    let root: URL
    let locations: PluginLocations
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("NotchTheRockTests-\(UUID().uuidString)")
        suiteName = "NotchTheRockTests.\(UUID().uuidString)"
        locations = PluginLocations(
            // Separate parents: the default file system ignores case, so PlugIns and Plugins would
            // be one folder.
            builtIn: root.appendingPathComponent("NotchTheRock.app/Contents/PlugIns"),
            user: root.appendingPathComponent("Application Support/Plugins"),
            data: root.appendingPathComponent("PluginData"),
            storagePrefix: "\(suiteName).plugin"
        )
        for folder in [locations.builtIn!, locations.user] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func newIdentifier() -> String {
        "com.example.t\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
    }

    /// Writes `<name>.notchplugin` with an Info.plist and `Contents/MacOS/<name>` holding `code`.
    @discardableResult
    func makeBundle(in folder: URL, name: String, identifier: String, sdk: String = "1.0", code: String = "code") throws -> URL {
        let bundle = folder.appendingPathComponent("\(name).notchplugin")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleExecutable": name,
            "NotchKitSDKVersion": sdk,
            "NotchPluginEntry": "notchkit_plugin_entry",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        try Data(code.utf8).write(to: macOS.appendingPathComponent(name))
        return bundle
    }

    func catalog(host: NotchHostModel = NotchHostModel(), open: PluginOpener? = nil) -> PluginCatalog {
        if let open {
            return PluginCatalog(host: host, locations: locations, defaults: defaults, open: open)
        }
        return PluginCatalog(host: host, locations: locations, defaults: defaults)
    }
}

/// Counts lifecycle calls. It posts an activity on `activate()` and does not clear it itself, so a
/// test sees whether the host removes it.
@MainActor
final class CountingPlugin: NotchPlugin {
    static let manifest = PluginManifest(id: "com.example.counting", name: "Counting", version: "1.0.0", symbol: "number", sdkVersion: NotchKitSDK.version)
    static var instances: [String: CountingPlugin] = [:]

    let context: NotchContext
    var activations = 0
    var deactivations = 0

    init(context: NotchContext) {
        self.context = context
        Self.instances[context.pluginID] = self
    }

    func activate() {
        activations += 1
        context.post(LiveActivity(id: "count", leading: { Text("\(activations)") }, trailing: { EmptyView() }))
    }

    func deactivate() {
        deactivations += 1
    }

    var expandedTab: PluginTab? {
        PluginTab(title: "Counting", symbol: "number") { Text("counting") }
    }
}

/// Stands in for `PluginLoader.load`: records which bundles were opened and returns `CountingPlugin`.
@MainActor
final class OpenLog {
    var opened: [String] = []
    var failures: [String: PluginLoadError] = [:]

    var opener: PluginOpener {
        { [self] info in
            opened.append(info.identifier)
            if let failure = failures[info.identifier] { throw failure }
            let manifest = PluginManifest(id: info.identifier, name: "Counting", version: "1.0.0", symbol: "number", sdkVersion: NotchKitSDK.version)
            return (manifest, CountingPlugin.self)
        }
    }
}

func setQuarantine(_ url: URL) {
    let value = "0081;00000000;Safari;"
    _ = setxattr(url.path, Quarantine.attribute, value, value.utf8.count, 0, XATTR_NOFOLLOW)
}

func hasQuarantine(_ url: URL) -> Bool {
    getxattr(url.path, Quarantine.attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
}

@MainActor
@Suite struct PluginCatalogTests {
    @Test func R03__unknown_user_bundle_needs_consent_and_its_code_is_not_opened() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let id = fixture.newIdentifier()
        try fixture.makeBundle(in: fixture.locations.user, name: "Sample", identifier: id)
        let log = OpenLog()
        let host = NotchHostModel()
        let catalog = fixture.catalog(host: host, open: log.opener)

        catalog.loadAll()

        let record = try #require(catalog.records.first)
        #expect(catalog.records.count == 1)
        #expect(record.state == .needsConsent(PluginCatalog.unknownReason))
        #expect(record.source == .user)
        #expect(record.identifier == id)
        #expect(record.name == "Sample")
        #expect(record.version == "1.2.3")
        #expect(log.opened.isEmpty)
        #expect(host.tabs.isEmpty)
    }

    @Test func R03__consent_pins_the_fingerprint_clears_quarantine_and_a_changed_bundle_asks_again() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let id = fixture.newIdentifier()
        let bundle = try fixture.makeBundle(in: fixture.locations.user, name: "Sample", identifier: id)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Sample")
        setQuarantine(bundle)
        setQuarantine(executable)
        #expect(hasQuarantine(executable))

        let log = OpenLog()
        let host = NotchHostModel()
        let catalog = fixture.catalog(host: host, open: log.opener)
        catalog.loadAll()
        try catalog.consent(to: bundle.path)

        #expect(catalog.records.first?.state == .on)
        #expect(log.opened == [id])
        #expect(host.tabs.map(\.pluginID) == [id])
        #expect(!hasQuarantine(bundle))
        #expect(!hasQuarantine(executable))

        // Next launch: the pinned fingerprint still matches, so the bundle loads without asking.
        let relaunchLog = OpenLog()
        let relaunched = fixture.catalog(open: relaunchLog.opener)
        relaunched.loadAll()
        #expect(relaunched.records.first?.state == .on)
        #expect(relaunchLog.opened == [id])

        // The code changes on disk: consent is asked again and the code is not opened.
        try Data("other code".utf8).write(to: executable)
        let changedLog = OpenLog()
        let changed = fixture.catalog(open: changedLog.opener)
        changed.loadAll()
        #expect(changed.records.first?.state == .needsConsent(PluginCatalog.changedReason))
        #expect(changedLog.opened.isEmpty)

        // A consent refers to the bundle as it was listed; a later change is refused.
        try Data("third code".utf8).write(to: executable)
        #expect(throws: ConsentFailure.self) { try changed.consent(to: bundle.path) }
        #expect(changedLog.opened.isEmpty)
        try changed.consent(to: bundle.path)
        #expect(changed.records.first?.state == .on)
        #expect(changedLog.opened == [id])
    }

    @Test func R03__turning_off_and_on_calls_deactivate_and_activate_exactly_once() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let id = fixture.newIdentifier()
        let bundle = try fixture.makeBundle(in: fixture.locations.builtIn!, name: "Counting", identifier: id)
        let log = OpenLog()
        let host = NotchHostModel()
        let catalog = fixture.catalog(host: host, open: log.opener)

        catalog.loadAll()
        let plugin = try #require(CountingPlugin.instances[id])
        #expect(catalog.records.first?.state == .on)
        #expect((plugin.activations, plugin.deactivations) == (1, 0))
        #expect(host.tabs.map(\.pluginID) == [id])
        #expect(host.liveActivity?.pluginID == id)

        catalog.setEnabled(false, for: bundle.path)
        catalog.setEnabled(false, for: bundle.path)
        #expect(catalog.records.first?.state == .off)
        #expect((plugin.activations, plugin.deactivations) == (1, 1))
        #expect(host.tabs.isEmpty)
        #expect(host.liveActivity == nil)

        catalog.setEnabled(true, for: bundle.path)
        catalog.setEnabled(true, for: bundle.path)
        #expect(catalog.records.first?.state == .on)
        #expect((plugin.activations, plugin.deactivations) == (2, 1))
        #expect(host.tabs.map(\.pluginID) == [id])
        #expect(log.opened == [id])

        // The choice survives a relaunch, and the code of a disabled bundle is not opened.
        catalog.setEnabled(false, for: bundle.path)
        let relaunchLog = OpenLog()
        let relaunched = fixture.catalog(open: relaunchLog.opener)
        relaunched.loadAll()
        #expect(relaunched.records.first?.state == .off)
        #expect(relaunchLog.opened.isEmpty)
        relaunched.setEnabled(true, for: bundle.path)
        #expect(relaunched.records.first?.state == .on)
        #expect(relaunchLog.opened == [id])
    }

    @Test func R03__refused_bundles_keep_a_readable_reason() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let builtIn = fixture.locations.builtIn!
        // Through the real loader: a newer SDK major and an executable that links out of the bundle.
        try fixture.makeBundle(in: builtIn, name: "Newer", identifier: fixture.newIdentifier(), sdk: "2.0")
        let outside = try fixture.makeBundle(in: builtIn, name: "Outside", identifier: fixture.newIdentifier())
        let executable = outside.appendingPathComponent("Contents/MacOS/Outside")
        try FileManager.default.removeItem(at: executable)
        try Data("elsewhere".utf8).write(to: fixture.root.appendingPathComponent("elsewhere"))
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: fixture.root.appendingPathComponent("elsewhere"))
        // A user bundle with a newer SDK shows the SDK reason instead of asking for consent.
        try fixture.makeBundle(in: fixture.locations.user, name: "UserNewer", identifier: fixture.newIdentifier(), sdk: "2.0")
        let catalog = fixture.catalog()
        catalog.loadAll()
        let reasons = catalog.records.map { record -> String in
            guard case .failed(let reason) = record.state else { return "not refused: \(record.state)" }
            return reason
        }
        #expect(reasons.count == 3)
        #expect(reasons[0].contains("NotchKit SDK 주 버전이 달라서 불러오지 않아요."))
        #expect(reasons[1].contains("실행 파일이 번들 밖을 가리켜요."))
        #expect(reasons[2].contains("NotchKit SDK 주 버전이 달라서 불러오지 않아요."))

        // A missing entry symbol keeps the loader's reason; a second bundle with a taken identifier is refused.
        let other = try PluginFixture()
        defer { other.cleanUp() }
        let missing = other.newIdentifier()
        let taken = other.newIdentifier()
        try other.makeBundle(in: other.locations.builtIn!, name: "A", identifier: missing)
        try other.makeBundle(in: other.locations.builtIn!, name: "B", identifier: taken)
        try other.makeBundle(in: other.locations.builtIn!, name: "C", identifier: taken)
        let log = OpenLog()
        log.failures[missing] = .missingEntrySymbol("notchkit_plugin_entry")
        let second = other.catalog(open: log.opener)
        second.loadAll()
        #expect(second.records.map(\.state) == [
            .failed(PluginLoadError.missingEntrySymbol("notchkit_plugin_entry").description),
            .on,
            .failed("같은 식별자(\(taken))를 쓰는 플러그인이 이미 있어요: \(second.records[1].id)"),
        ])
        #expect(log.opened == [missing, taken])
    }

    @Test func R03__reload_lists_new_bundles_and_marks_changed_or_removed_loaded_ones() throws {
        let fixture = try PluginFixture()
        defer { fixture.cleanUp() }
        let log = OpenLog()
        let catalog = fixture.catalog(open: log.opener)
        catalog.loadAll()
        #expect(catalog.records.isEmpty)

        let first = fixture.newIdentifier()
        let a = try fixture.makeBundle(in: fixture.locations.user, name: "A", identifier: first)
        catalog.reload()
        #expect(catalog.records.map(\.state) == [.needsConsent(PluginCatalog.unknownReason)])
        try catalog.consent(to: a.path)
        let b = try fixture.makeBundle(in: fixture.locations.user, name: "B", identifier: fixture.newIdentifier())
        catalog.reload()
        #expect(catalog.records.map(\.state) == [.on, .needsConsent(PluginCatalog.unknownReason)])
        #expect(catalog.records.map(\.needsRestart) == [false, false])

        try Data("changed".utf8).write(to: a.appendingPathComponent("Contents/MacOS/A"))
        catalog.reload()
        #expect(catalog.records.first?.state == .on)
        #expect(catalog.records.first?.needsRestart == true)
        #expect(log.opened == [first])

        try FileManager.default.removeItem(at: a)
        try FileManager.default.removeItem(at: b)
        catalog.reload()
        #expect(catalog.records.map(\.id) == [a.path])
        #expect(catalog.records.first?.needsRestart == true)
    }
}
