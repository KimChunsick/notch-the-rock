import CryptoKit
import Darwin
import Foundation

/// SHA-256 over every directory, file and symbolic link inside a bundle, in path order. Links are
/// hashed as their target text and never followed, so the fingerprint covers exactly what the
/// bundle holds and nothing it points to.
enum PluginFingerprint {
    static func of(_ bundleURL: URL) throws -> String {
        let root = bundleURL.resolvingSymlinksInPath().path
        let manager = FileManager.default
        var hasher = SHA256()
        func add(_ text: String) {
            hasher.update(data: Data((text + "\0").utf8))
        }
        for path in try manager.subpathsOfDirectory(atPath: root).sorted() {
            let full = root + "/" + path
            var status = stat()
            guard lstat(full, &status) == 0 else {
                throw ConsentFailure("\(full): \(String(cString: strerror(errno)))")
            }
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                add("d"); add(path)
            case S_IFLNK:
                add("l"); add(path); add(try manager.destinationOfSymbolicLink(atPath: full))
            case S_IFREG:
                let data = try Data(contentsOf: URL(fileURLWithPath: full))
                add("f"); add(path); add(String(data.count))
                hasher.update(data: data)
            default:
                throw ConsentFailure("번들 안에 일반 파일이 아닌 항목이 있어요: \(full)")
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    /// Removes the quarantine attribute from the bundle and everything in it, without following
    /// links, so the system does not stop the consented code from loading.
    static func clear(_ bundleURL: URL) throws {
        let root = bundleURL.resolvingSymlinksInPath().path
        let paths = [root] + (try FileManager.default.subpathsOfDirectory(atPath: root)).map { root + "/" + $0 }
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
