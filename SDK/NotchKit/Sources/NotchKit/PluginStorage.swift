import Foundation
import Security

/// A plugin's private storage: a directory, a defaults suite and keychain items, all scoped to
/// the plugin by the host.
///
/// Keychain calls never show a dialog. A call that would need the user, because the item's access
/// does not include this app or the keychain is locked, fails with a `KeychainError` whose
/// `needsAccess` is true. Keychain calls can still wait on the system, so keep them off the main
/// thread.
///
/// Sendable: every property is immutable, `UserDefaults` is documented as thread-safe, and keychain
/// calls take turns (see `withoutUserInteraction`).
public struct PluginStorage: @unchecked Sendable {
    /// The plugin's own directory (created with mode 0700).
    public let directory: URL
    /// Preferences for this plugin only.
    public let defaults: UserDefaults
    /// Keychain service name under which this plugin's items are stored.
    public let keychainService: String
    /// The keychain file every item call is limited to; nil for the user's keychains. Tests name a
    /// temporary keychain here.
    let keychainPath: String?

    /// Creates `directory` when missing. Called by the host, not by plugins.
    public init(directory: URL, defaultsSuiteName: String, keychainService: String) throws {
        try self.init(directory: directory, defaultsSuiteName: defaultsSuiteName, keychainService: keychainService, keychainPath: nil)
    }

    init(directory: URL, defaultsSuiteName: String, keychainService: String, keychainPath: String?) throws {
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
        self.keychainPath = keychainPath
    }

    /// The data stored for `account`, or nil when there is none. An item this app may not read
    /// without asking throws an error whose `needsAccess` is true.
    public func keychainData(for account: String) throws(KeychainError) -> Data? {
        var query = try matchQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = withoutUserInteraction { SecItemCopyMatching(query as CFDictionary, &result) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    /// Stores `data` for `account`, replacing any earlier value. An earlier item keeps its access;
    /// a new item gets `.thisApp`. Items stay on this Mac.
    public func setKeychainData(_ data: Data, for account: String) throws(KeychainError) {
        let query = try matchQuery(account)
        let update = withoutUserInteraction {
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        try add(data, for: account, access: .thisApp)
    }

    /// Stores `data` for `account` with `access`, replacing any earlier item: the earlier item is
    /// deleted first, so when adding the new one fails the account has no item. Items stay on this
    /// Mac. (SDK 1.2)
    public func setKeychainData(_ data: Data, for account: String, access: KeychainAccess) throws(KeychainError) {
        try deleteKeychainData(for: account)
        try add(data, for: account, access: access)
    }

    /// Removes the item for `account`; removing a missing item is not an error.
    public func deleteKeychainData(for account: String) throws(KeychainError) {
        let query = try matchQuery(account)
        let status = withoutUserInteraction { SecItemDelete(query as CFDictionary) }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    private func add(_ data: Data, for account: String, access: KeychainAccess) throws(KeychainError) {
        var item = itemAttributes(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if let keychain = try keychain() {
            item[kSecUseKeychain as String] = keychain
        }
        if access == .anyApplication {
            item[kSecAttrAccess as String] = try Self.anyApplicationAccess(named: "\(keychainService) \(account)")
        }
        let status = withoutUserInteraction { SecItemAdd(item as CFDictionary, nil) }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func itemAttributes(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
    }

    private func matchQuery(_ account: String) throws(KeychainError) -> [String: Any] {
        var query = itemAttributes(account)
        if let keychain = try keychain() {
            query[kSecMatchSearchList as String] = [keychain]
        }
        return query
    }

    private func keychain() throws(KeychainError) -> SecKeychain? {
        guard let keychainPath else { return nil }
        var keychain: SecKeychain?
        let status = SecKeychainOpen(keychainPath, &keychain)
        guard status == errSecSuccess, let keychain else { throw KeychainError(status: status) }
        return keychain
    }

    /// An access whose decrypt entries trust every application (no application list), as Keychain
    /// Access's "Allow all applications to access this item".
    private static func anyApplicationAccess(named name: String) throws(KeychainError) -> SecAccess {
        var created: SecAccess?
        let status = SecAccessCreate(name as CFString, nil, &created)
        guard status == errSecSuccess, let access = created else { throw KeychainError(status: status) }
        for acl in SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL] ?? [] {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            var result = SecACLCopyContents(acl, &applications, &description, &prompt)
            if result == errSecSuccess {
                result = SecACLSetContents(acl, nil, description ?? name as CFString, prompt)
            }
            guard result == errSecSuccess else { throw KeychainError(status: result) }
        }
        return access
    }

    /// Serializes keychain calls while the process-wide interaction switch is off.
    private static let interaction = NSLock()

    /// Runs `body` with keychain dialogs turned off, so a call that would ask the user fails with
    /// `errSecAuthFailed` or `errSecInteractionNotAllowed` instead. `kSecUseAuthenticationUIFail`
    /// and an `LAContext` with `interactionNotAllowed` do not stop the file-based keychain's access
    /// and unlock dialogs (checked on macOS 26.5); this switch does. It is per process, so calls take
    /// turns and the earlier setting comes back afterwards.
    private func withoutUserInteraction(_ body: () -> OSStatus) -> OSStatus {
        Self.interaction.lock()
        defer { Self.interaction.unlock() }
        var allowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }
}

/// Who may read a keychain item without macOS asking the user. (SDK 1.2)
public enum KeychainAccess: Hashable, Sendable {
    /// Only the app that stored the item, the macOS default. The access is tied to the app's code
    /// signature, so after an update signed differently reads fail with `needsAccess` until the
    /// user allows the app in Keychain Access.
    case thisApp
    /// Every application on this Mac reads the item without a dialog. Weaker protection: any
    /// program running as the user can read the value.
    case anyApplication
}

public struct KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }

    /// Whether the call would have needed the user: the item's access does not include this app,
    /// or the keychain is locked. `PluginStorage` never asks, so such a call fails with this.
    /// An item that does not exist is not an error: `keychainData(for:)` returns nil. (SDK 1.2)
    public var needsAccess: Bool {
        status == errSecAuthFailed || status == errSecInteractionNotAllowed
    }

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "keychain error \(status): \(message)"
    }
}
