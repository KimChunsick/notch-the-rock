import Darwin
import Foundation

/// Info.plist keys of a `.notchplugin` bundle besides the standard `CFBundle*` keys.
public enum PluginBundleKey {
    /// SDK version the plugin was built against, `"major.minor"`.
    public static let sdkVersion = "NotchKitSDKVersion"
    /// C symbol of the entry function; defaults to `NotchPluginEntry.defaultSymbol`.
    public static let entrySymbol = "NotchPluginEntry"
}

/// What a `.notchplugin` bundle declares in `Contents/Info.plist`, read without running its code.
///
/// Layout: `<Name>.notchplugin/Contents/{Info.plist, MacOS/<CFBundleExecutable>, Resources/}`.
public struct PluginBundleInfo: Hashable, Sendable {
    public let bundleURL: URL
    public let identifier: String
    public let sdkVersion: SDKVersion
    public let entrySymbol: String
    public let executableURL: URL

    public init(contentsOf bundleURL: URL) throws {
        let plistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw PluginLoadError.notABundle(bundleURL)
        }
        guard let data = try? Data(contentsOf: plistURL),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw PluginLoadError.unreadableInfoPlist(bundleURL) }

        func value(_ key: String) throws -> String {
            guard let text = plist[key] as? String, !text.isEmpty else { throw PluginLoadError.missingKey(key) }
            return text
        }
        let identifier = try value("CFBundleIdentifier")
        guard PluginManifest.isValidIdentifier(identifier) else { throw PluginLoadError.invalidIdentifier(identifier) }
        let executable = try value("CFBundleExecutable")
        // The executable must stay inside the bundle, which is what the user consents to.
        guard !executable.contains("/"), executable != ".", executable != ".." else {
            throw PluginLoadError.invalidExecutableName(executable)
        }
        let versionText = try value(PluginBundleKey.sdkVersion)
        guard let sdkVersion = SDKVersion(versionText) else { throw PluginLoadError.malformedSDKVersion(versionText) }

        self.bundleURL = bundleURL
        self.identifier = identifier
        self.sdkVersion = sdkVersion
        self.entrySymbol = (plist[PluginBundleKey.entrySymbol] as? String) ?? NotchPluginEntry.defaultSymbol
        self.executableURL = bundleURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
    }
}

/// A plugin class resolved from a loaded binary, with its checked manifest.
public struct LoadedPlugin {
    public let manifest: PluginManifest
    public let pluginType: any NotchPlugin.Type
}

/// Loads plugin binaries. The app and `notchkit-probe` both load bundles through `load(_:)`.
@MainActor
public enum PluginLoader {
    /// Loads a bundle the way the app does: rejects an incompatible `NotchKitSDKVersion` before any
    /// plugin code runs, then opens the executable, resolves the entry symbol and checks the
    /// manifest against the bundle. Plugin code runs from `dlopen` on, so user consent and hash
    /// checks must happen before this call. Loaded binaries are never unloaded.
    public static func load(_ info: PluginBundleInfo) throws -> LoadedPlugin {
        let host = NotchKitSDK.version
        guard host.supports(info.sdkVersion) else {
            throw PluginLoadError.incompatibleSDK(required: info.sdkVersion, host: host)
        }
        let plugin = try resolve(binary: info.executableURL, symbol: info.entrySymbol)
        guard plugin.manifest.id == info.identifier else {
            throw PluginLoadError.identifierMismatch(bundle: info.identifier, manifest: plugin.manifest.id)
        }
        return plugin
    }

    /// Opens a plugin binary, calls its entry function and checks the manifest it declares.
    /// Build tooling uses this on a binary that is not in a bundle yet.
    public static func resolve(binary: URL, symbol: String = NotchPluginEntry.defaultSymbol) throws -> LoadedPlugin {
        guard let handle = dlopen(binary.path, RTLD_NOW | RTLD_LOCAL) else {
            throw PluginLoadError.openFailed(dlerror().map { String(cString: $0) } ?? binary.path)
        }
        guard let address = dlsym(handle, symbol) else { throw PluginLoadError.missingEntrySymbol(symbol) }
        let entryFunction = unsafeBitCast(address, to: NotchPluginEntryFunction.self)
        let object = Unmanaged<AnyObject>.fromOpaque(entryFunction()).takeRetainedValue()
        // A plugin that carries its own NotchKit copy returns an instance of a different class.
        guard let entry = object as? NotchPluginEntry else { throw PluginLoadError.foreignEntry }

        let manifest = entry.pluginType.manifest
        guard PluginManifest.isValidIdentifier(manifest.id) else { throw PluginLoadError.invalidIdentifier(manifest.id) }
        let host = NotchKitSDK.version
        guard host.supports(manifest.sdkVersion) else {
            throw PluginLoadError.incompatibleSDK(required: manifest.sdkVersion, host: host)
        }
        return LoadedPlugin(manifest: manifest, pluginType: entry.pluginType)
    }
}

/// Why a bundle was not loaded. `description` is the reason shown to the user.
public enum PluginLoadError: Error, Hashable, CustomStringConvertible {
    case notABundle(URL)
    case unreadableInfoPlist(URL)
    case missingKey(String)
    case invalidIdentifier(String)
    case invalidExecutableName(String)
    case malformedSDKVersion(String)
    case incompatibleSDK(required: SDKVersion, host: SDKVersion)
    case openFailed(String)
    case missingEntrySymbol(String)
    case foreignEntry
    case identifierMismatch(bundle: String, manifest: String)

    public var description: String {
        switch self {
        case .notABundle(let url):
            return "\(url.path)에 Contents/Info.plist가 없어요. .notchplugin 번들이 아니에요."
        case .unreadableInfoPlist(let url):
            return "\(url.path)의 Info.plist를 읽을 수 없어요."
        case .missingKey(let key):
            return "Info.plist에 \(key) 값이 없어요."
        case .invalidIdentifier(let id):
            return "플러그인 식별자가 역도메인 형식(예: com.example.clock)이 아니에요: \(id)"
        case .invalidExecutableName(let name):
            return "CFBundleExecutable 값은 번들 안 Contents/MacOS에 있는 파일 이름이어야 해요: \(name)"
        case .malformedSDKVersion(let text):
            return "\(PluginBundleKey.sdkVersion) 값은 '주.부' 형식(예: 1.0)이어야 해요: \(text)"
        case .incompatibleSDK(let required, let host) where required.major != host.major:
            return "NotchKit SDK 주 버전이 달라서 불러오지 않아요. (플러그인 SDK \(required), 앱 SDK \(host))"
        case .incompatibleSDK(let required, let host):
            return "앱의 NotchKit SDK가 플러그인보다 오래돼서 불러오지 않아요. 앱을 업데이트해 주세요. (플러그인 SDK \(required), 앱 SDK \(host))"
        case .openFailed(let message):
            return "플러그인 실행 파일을 열지 못했어요: \(message)"
        case .missingEntrySymbol(let symbol):
            return "진입 함수를 찾지 못했어요: \(symbol). @_cdecl(\"\(symbol)\") 함수를 내보냈는지 확인해 주세요."
        case .foreignEntry:
            return "진입 함수가 돌려준 값이 이 앱의 NotchKit 타입이 아니에요. 플러그인이 NotchKit을 @rpath/libNotchKit.dylib로 동적 링크했는지 확인해 주세요."
        case .identifierMismatch(let bundle, let manifest):
            return "Info.plist의 식별자(\(bundle))와 PluginManifest의 id(\(manifest))가 달라요."
        }
    }
}
