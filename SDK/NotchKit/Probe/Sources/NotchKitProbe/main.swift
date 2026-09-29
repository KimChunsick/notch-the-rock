import Foundation
import NotchKit

// notchkit-probe: loads a .notchplugin the way NotchTheRock does and prints what it found.
//
//   notchkit-probe <Name.notchplugin>
//       Reads Info.plist, rejects an incompatible NotchKitSDKVersion before running any plugin
//       code, dlopens the executable, resolves the entry symbol, creates the plugin against a stub
//       host and prints its manifest. Exits 1 with the reason on any failure.
//   notchkit-probe --manifest <binary> [<entry-symbol>]
//       Prints the manifest of a plugin binary that is not in a bundle yet as key=value lines.
//       build-plugin.sh derives the bundle's Info.plist from this output.

/// Accepts every call and does nothing; attention requests are dismissed.
@MainActor
final class ProbeHost: NotchHost {
    func post(_ activity: LiveActivity, from pluginID: String) {}
    func clearActivity(id: String, from pluginID: String) {}
    func showHUD(_ hud: HUD, duration: Duration, from pluginID: String) {}
    func present(_ takeover: Takeover, from pluginID: String) {}
    func requestAttention(_ request: AttentionRequest, from pluginID: String) async -> AttentionResponse { .dismissed }
    func expand(toTabOf pluginID: String) {}
    func collapse(from pluginID: String) {}
    var isAccessibilityTrusted: Bool { false }
    func requestAccessibility(from pluginID: String) {}
    func log(_ level: LogLevel, _ message: String, from pluginID: String) {}
}

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func probeBundle(at path: String) throws -> [String] {
    let info = try PluginBundleInfo(contentsOf: URL(fileURLWithPath: path))
    let loaded = try PluginLoader.load(info)
    let id = loaded.manifest.id
    let storage = try PluginStorage(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("notchkit-probe/\(id)"),
        defaultsSuiteName: "notchkit-probe.\(id)",
        keychainService: "notchkit-probe.\(id)"
    )
    let plugin = loaded.pluginType.init(context: NotchContext(pluginID: id, host: ProbeHost(), storage: storage))
    return [
        "bundle: \(info.bundleURL.path)",
        "id: \(loaded.manifest.id)",
        "name: \(loaded.manifest.name)",
        "version: \(loaded.manifest.version)",
        "symbol: \(loaded.manifest.symbol)",
        "sdk: \(loaded.manifest.sdkVersion) (bundle \(info.sdkVersion), host \(NotchKitSDK.version))",
        "entry: \(info.entrySymbol)",
        "expandedTab: \(plugin.expandedTab?.title ?? "-")",
        "settingsView: \(plugin.settingsView == nil ? "-" : "yes")",
        "OK: 앱과 같은 방식으로 불러와서 \(type(of: plugin)) 인스턴스를 만들었어요.",
    ]
}

@MainActor
func probeManifest(binary: String, symbol: String) throws -> [String] {
    let manifest = try PluginLoader.resolve(binary: URL(fileURLWithPath: binary), symbol: symbol).manifest
    let fields = [
        ("id", manifest.id),
        ("name", manifest.name),
        ("version", manifest.version),
        ("symbol", manifest.symbol),
        ("sdk", manifest.sdkVersion.description),
    ]
    if let (key, _) = fields.first(where: { $0.1.contains(where: \.isNewline) || $0.1.isEmpty }) {
        throw ProbeFailure(description: "PluginManifest의 \(key) 값이 비어 있거나 줄바꿈을 포함해요.")
    }
    return fields.map { "\($0.0)=\($0.1)" }
}

let usage = """
    사용법: notchkit-probe <Name.notchplugin>
           notchkit-probe --manifest <plugin-binary> [<entry-symbol>]
    """

let status: Int32 = MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let lines: [String]
    do {
        switch arguments.first {
        case "--manifest" where arguments.count == 2 || arguments.count == 3:
            lines = try probeManifest(binary: arguments[1], symbol: arguments.count == 3 ? arguments[2] : NotchPluginEntry.defaultSymbol)
        case let path? where arguments.count == 1 && !path.hasPrefix("-"):
            lines = try probeBundle(at: path)
        default:
            FileHandle.standardError.write(Data((usage + "\n").utf8))
            return 2
        }
    } catch {
        FileHandle.standardError.write(Data("notchkit-probe: \(error)\n".utf8))
        return 1
    }
    print(lines.joined(separator: "\n"))
    return 0
}
exit(status)
