import CryptoKit
import Darwin
import Foundation

/// SHA-256 over every directory and file inside a bundle, in path order. A bundle holding a
/// symbolic link, or being one, has no fingerprint: see `BundleContents`.
enum PluginFingerprint {
    static func of(_ bundleURL: URL) throws -> String {
        var hasher = SHA256()
        func add(_ text: String) {
            hasher.update(data: Data((text + "\0").utf8))
        }
        for entry in try BundleContents.entries(of: bundleURL) {
            switch entry.kind {
            case .directory:
                add("d"); add(entry.path)
            case .file:
                let full = bundleURL.path + "/" + entry.path
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: full)) else {
                    throw ConsentFailure("번들 파일을 읽지 못했어요: \(full)")
                }
                add("f"); add(entry.path); add(String(data.count))
                hasher.update(data: data)
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// What a user bundle may hold: directories and regular files only. A symbolic link, as the bundle
/// or inside it, could bring in files from outside the bundle that the fingerprint does not cover,
/// and the `.notchplugin` layout needs none.
enum BundleContents {
    enum Kind {
        case directory
        case file
    }

    /// Every entry below `root` as a relative path, parents before their children.
    static func entries(of root: URL) throws -> [(path: String, kind: Kind)] {
        guard try kind(root.path, shownAs: root.lastPathComponent) == .directory else {
            throw ConsentFailure("번들이 폴더가 아니에요: \(root.path)")
        }
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: root.path) else {
            throw ConsentFailure("번들 폴더를 읽지 못했어요: \(root.path)")
        }
        return try paths.sorted().map { ($0, try kind(root.path + "/" + $0, shownAs: $0)) }
    }

    private static func kind(_ path: String, shownAs name: String) throws -> Kind {
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw ConsentFailure("번들 파일을 읽지 못했어요: \(path): \(String(cString: strerror(errno)))")
        }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: throw ConsentFailure("심볼릭 링크는 번들 밖을 가리킬 수 있어서 불러오지 않아요. 링크를 실제 파일로 바꿔 주세요: \(name)")
        default: throw ConsentFailure("번들 안에 일반 파일이 아닌 항목이 있어요: \(name)")
        }
    }
}

/// Which user bundles the user allowed to run, each pinned to the fingerprint of the bundle they
/// allowed. Kept in the app's defaults as `[plugin identifier: fingerprint]`.
struct PluginConsentStore {
    enum Decision: Equatable {
        /// Never allowed: ask.
        case unknown
        /// Allowed, but the bundle changed since: ask again.
        case changed
        case consented
    }

    static let key = "PluginConsents"
    let defaults: UserDefaults

    func decision(for identifier: String, fingerprint: String) -> Decision {
        switch pinned[identifier] {
        case nil: .unknown
        case fingerprint: .consented
        default: .changed
        }
    }

    func pin(_ identifier: String, fingerprint: String) {
        var pinned = pinned
        pinned[identifier] = fingerprint
        defaults.set(pinned, forKey: Self.key)
    }

    private var pinned: [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }
}

enum Quarantine {
    static let attribute = "com.apple.quarantine"

    /// Removes the quarantine attribute from the app's copy of a consented bundle and everything in
    /// it, without following links, so the system does not stop the consented code from loading.
    static func clear(_ bundleURL: URL) throws {
        let root = bundleURL.path
        let paths = [root] + (try BundleContents.entries(of: bundleURL)).map { root + "/" + $0.path }
        for path in paths where removexattr(path, attribute, XATTR_NOFOLLOW) != 0 && errno != ENOATTR {
            throw ConsentFailure("격리 속성을 지우지 못했어요: \(path): \(String(cString: strerror(errno)))")
        }
    }
}

/// Why a consent could not be given; `description` is shown to the user.
struct ConsentFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
