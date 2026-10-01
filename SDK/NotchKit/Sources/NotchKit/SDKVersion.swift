/// A NotchKit SDK version, `major.minor`.
///
/// Compatibility rule: a host whose SDK is `H` runs a plugin built against `P` when
/// `H.major == P.major` and `H.minor >= P.minor`. A new major version may break plugins; a new
/// minor version only adds API.
@frozen
public struct SDKVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int

    @inlinable
    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    /// Parses `"major.minor"`, the form used by the `NotchKitSDKVersion` Info.plist key.
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
              let major = Int(parts[0]), let minor = Int(parts[1])
        else { return nil }
        self.init(major: major, minor: minor)
    }

    public var description: String { "\(major).\(minor)" }

    /// Whether a host providing this SDK version can run code built against `required`.
    public func supports(_ required: SDKVersion) -> Bool {
        major == required.major && minor >= required.minor
    }

    public static func < (lhs: SDKVersion, rhs: SDKVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}

public enum NotchKitSDK {
    /// The SDK version this code was compiled against.
    ///
    /// The value is emitted into the calling binary, so a plugin records the version it was
    /// built with rather than the version of the host that later loads it. Inside NotchKit itself
    /// (the loader) it is the version of the loaded dylib.
    @_alwaysEmitIntoClient
    public static var version: SDKVersion { SDKVersion(major: 1, minor: 2) }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
}
