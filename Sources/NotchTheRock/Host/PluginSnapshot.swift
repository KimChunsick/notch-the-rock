import Foundation
import NotchKit

/// The app's own copies of consented user bundles, `<cache>/<identifier>/<Name>.notchplugin`. The
/// user folder is only where a bundle comes from: the fingerprint check, the library check,
/// quarantine removal and loading all use the copy, so the code that runs is the code the user
/// allowed, whatever happens in the user folder afterwards.
struct PluginSnapshots {
    let cache: URL

    /// The copy of `source` whose fingerprint is `fingerprint`, checked and ready to load. An
    /// existing copy is fingerprinted again and reused; otherwise `source` is copied and the copy
    /// must have that fingerprint, or this throws `SnapshotMismatch`.
    func prepare(_ source: URL, identifier: String, fingerprint: String) throws -> PluginBundleInfo {
        let manager = FileManager.default
        let folder = cache.appendingPathComponent(identifier)
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        if (try? PluginFingerprint.of(copy)) == fingerprint {
            return try Self.checked(copy)
        }

        let staging = cache.appendingPathComponent(".staging-\(UUID().uuidString)")
        let staged = staging.appendingPathComponent(source.lastPathComponent)
        defer { try? manager.removeItem(at: staging) }
        let entries = try BundleContents.entries(of: source)
        try manager.createDirectory(at: staged, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for entry in entries {
            let target = staged.path + "/" + entry.path
            switch entry.kind {
            case .directory: try manager.createDirectory(atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            case .file: try manager.copyItem(atPath: source.path + "/" + entry.path, toPath: target)
            }
        }
        guard try PluginFingerprint.of(staged) == fingerprint else { throw SnapshotMismatch() }
        _ = try Self.checked(staged)
        try Quarantine.clear(staged)

        // A previous copy may be loaded: it is moved away whole, never rewritten in place.
        let previous = cache.appendingPathComponent(".previous-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: previous) }
        if (try? manager.attributesOfItem(atPath: folder.path)) != nil {
            try manager.moveItem(at: folder, to: previous)
        }
        try manager.moveItem(at: staging, to: folder)
        return try PluginBundleInfo(contentsOf: copy)
    }

    private static func checked(_ bundle: URL) throws -> PluginBundleInfo {
        let info = try PluginBundleInfo(contentsOf: bundle)
        try LinkedLibraries.check(info.executableURL)
        return info
    }
}

/// The copy made for a consent does not have the fingerprint the user saw: the bundle in the user
/// folder changed in between.
struct SnapshotMismatch: Error {}

/// The libraries a user plugin's executable links. The fingerprint covers only the bundle, so the
/// executable may link nothing but the system's libraries and the app's NotchKit.
enum LinkedLibraries {
    static func check(_ executable: URL) throws {
        guard let data = try? Data(contentsOf: executable) else {
            throw ConsentFailure("실행 파일을 읽지 못했어요: \(executable.path)")
        }
        for library in try libraries(in: [UInt8](data)) where !isAllowed(library) {
            throw ConsentFailure("시스템 라이브러리와 NotchKit 말고는 불러올 수 없어요. 번들 밖 코드를 불러오는 플러그인은 불러오지 않아요: \(library)")
        }
    }

    /// `/System/Volumes/Data` is the user's data volume, so only `/System/Library/` counts as the
    /// system; `..` could leave either folder.
    static func isAllowed(_ library: String) -> Bool {
        guard !library.split(separator: "/").contains("..") else { return false }
        return library == "@rpath/libNotchKit.dylib" || library.hasPrefix("/usr/lib/") || library.hasPrefix("/System/Library/")
    }

    /// The install names every architecture of a Mach-O file, thin or universal, loads.
    static func libraries(in bytes: [UInt8]) throws -> [String] {
        let magic = try word(bytes, 0, bigEndian: true)
        guard magic == 0xCAFE_BABE || magic == 0xCAFE_BABF else { return try sliceLibraries(bytes[...]) }
        let wide = magic == 0xCAFE_BABF
        var libraries: [String] = []
        let count = try word(bytes, 4, bigEndian: true)
        for index in 0..<Int(count) {
            // fat_arch: offset and size are 32-bit at 8 and 12; fat_arch_64: 64-bit at 8 and 16.
            let entry = 8 + index * (wide ? 32 : 20)
            func field(_ at: Int) throws -> UInt64 {
                try word(bytes, entry + at, bigEndian: true)
            }
            let offset = try wide ? field(8) << 32 | field(12) : field(8)
            let size = try wide ? field(16) << 32 | field(20) : field(12)
            guard offset <= UInt64(bytes.count), size <= UInt64(bytes.count) - offset else { throw malformed }
            libraries += try sliceLibraries(bytes[Int(offset)..<Int(offset + size)])
        }
        return libraries
    }

    /// LC_LOAD_DYLIB, LC_LAZY_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD_DYLIB.
    private static let loadCommands: Set<UInt64> = [0xC, 0x20, 0x8000_0018, 0x8000_001F, 0x8000_0023]
    private static let malformed = ConsentFailure("실행 파일이 올바른 Mach-O 형식이 아니에요.")

    private static func sliceLibraries(_ slice: ArraySlice<UInt8>) throws -> [String] {
        let bytes = Array(slice)
        let magic = try word(bytes, 0)
        let headerSize = switch magic {
        case 0xFEED_FACF: 32
        case 0xFEED_FACE: 28
        default: throw malformed
        }
        let end = headerSize + Int(try word(bytes, 20))
        guard end <= bytes.count else { throw malformed }
        var libraries: [String] = []
        var offset = headerSize
        let count = try word(bytes, 16)
        for _ in 0..<count {
            guard offset + 8 <= end else { throw malformed }
            let command = try word(bytes, offset)
            let size = Int(try word(bytes, offset + 4))
            guard size >= 8, size <= end - offset else { throw malformed }
            if loadCommands.contains(command) {
                let name = try offset + Int(word(bytes, offset + 8))
                guard size >= 12, name >= offset + 12, name < offset + size,
                      let library = String(bytes: bytes[name..<offset + size].prefix { $0 != 0 }, encoding: .utf8)
                else { throw malformed }
                libraries.append(library)
            }
            offset += size
        }
        return libraries
    }

    private static func word(_ bytes: [UInt8], _ offset: Int, bigEndian: Bool = false) throws -> UInt64 {
        guard offset >= 0, offset + 4 <= bytes.count else { throw malformed }
        let value = bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return UInt64(bigEndian ? value : value.byteSwapped)
    }
}
