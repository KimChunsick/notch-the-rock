import Foundation
import Security

/// A plugin's private storage: a directory, a defaults suite and keychain items, all scoped to
/// the plugin by the host.
public struct PluginStorage {
    /// The plugin's own directory (created with mode 0700).
    public let directory: URL
    /// Preferences for this plugin only.
    public let defaults: UserDefaults
    /// Keychain service name under which this plugin's items are stored.
    public let keychainService: String

    /// Creates `directory` when missing. Called by the host, not by plugins.
    public init(directory: URL, defaultsSuiteName: String, keychainService: String) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSDebugDescriptionErrorKey: "invalid defaults suite \(defaultsSuiteName)"])
        }
        self.directory = directory
        self.defaults = defaults
        self.keychainService = keychainService
    }

    /// The data stored for `account`, or nil when there is none.
    public func keychainData(for account: String) throws(KeychainError) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    /// Stores `data` for `account`, replacing any earlier value. Items stay on this Mac.
    public func setKeychainData(_ data: Data, for account: String) throws(KeychainError) {
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = baseQuery(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let add = SecItemAdd(item as CFDictionary, nil)
        guard add == errSecSuccess else { throw KeychainError(status: add) }
    }

    /// Removes the item for `account`; removing a missing item is not an error.
    public func deleteKeychainData(for account: String) throws(KeychainError) {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }
}

public struct KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "keychain error \(status): \(message)"
    }
}
