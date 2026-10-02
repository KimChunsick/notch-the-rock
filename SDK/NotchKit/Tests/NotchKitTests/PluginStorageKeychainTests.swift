import Foundation
import Security
import Testing
@testable import NotchKit

/// A keychain file of its own in a temporary folder, created unlocked and deleted again. The
/// user's keychains are never searched: every `PluginStorage` here names this file.
private final class TemporaryKeychain {
    let folder: URL
    let path: String
    let keychain: SecKeychain

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchKitKeychainTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        path = folder.appendingPathComponent("test.keychain").path
        let password = "notchkit-tests"
        var keychain: SecKeychain?
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &keychain)
        guard status == errSecSuccess, let keychain else { throw KeychainError(status: status) }
        self.keychain = keychain
    }

    func storage() throws -> PluginStorage {
        try PluginStorage(
            directory: folder.appendingPathComponent("storage"),
            defaultsSuiteName: "NotchKitKeychainTests",
            keychainService: "NotchKitKeychainTests.\(UUID().uuidString)",
            keychainPath: path
        )
    }

    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Runs `/usr/bin/security` with `arguments`, which name the temporary keychain file; a run still
/// going after `timeout` (a dialog waiting for the user) is stopped and returns nil.
private func security(_ arguments: [String], timeout: TimeInterval = 10) throws -> (status: Int32, output: String)? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    guard !process.isRunning else {
        process.terminate()
        process.waitUntilExit()
        return nil
    }
    return (process.terminationStatus, String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
}

/// Runs `body` on another thread and waits up to `timeout`; nil when it is still running, as a call
/// waiting behind a keychain dialog would be.
private func finished<T: Sendable>(within timeout: TimeInterval = 10, _ body: @escaping @Sendable () -> T) -> T? {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    DispatchQueue.global().async {
        result = body()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    return result
}

@Suite(.serialized) struct PluginStorageKeychainTests {
    /// An item another program stored for itself: reading it would make macOS ask the user, so the
    /// read fails at once with an error that says so, unlike an item that is not there.
    @Test func R09__a_read_that_needs_the_user_fails_instead_of_asking() throws {
        let keychain = try TemporaryKeychain()
        let storage = try keychain.storage()
        let added = try #require(try security(["add-generic-password", "-s", storage.keychainService, "-a", "foreign", "-w", "secret", keychain.path]))
        #expect(added.status == 0, "\(added.output)")

        let read = try #require(finished { Result { () throws(KeychainError) in try storage.keychainData(for: "foreign") } }, "the read waited for the user")
        #expect(throws: KeychainError.self) { try read.get() }
        if case .failure(let error) = read {
            #expect(error.needsAccess, "\(error)")
        }
        #expect(try storage.keychainData(for: "missing") == nil)
    }

    /// A locked keychain is not unlocked with a dialog either.
    @Test func R09__a_read_from_a_locked_keychain_fails_instead_of_asking() throws {
        let keychain = try TemporaryKeychain()
        let storage = try keychain.storage()
        try storage.setKeychainData(Data("key".utf8), for: "account", access: .anyApplication)
        #expect(SecKeychainLock(keychain.keychain) == errSecSuccess)

        let read = try #require(finished { Result { () throws(KeychainError) in try storage.keychainData(for: "account") } }, "the read waited for the user")
        if case .failure(let error) = read {
            #expect(error.needsAccess, "\(error)")
        } else {
            Issue.record("a locked keychain was read: \(read)")
        }
    }

    /// An item stored for any application is read by another program, `security`, without a
    /// dialog. Storing it again replaces the value and keeps that access.
    @Test func R09__an_item_for_any_application_is_read_by_another_program_without_asking() throws {
        let keychain = try TemporaryKeychain()
        let storage = try keychain.storage()
        try storage.setKeychainData(Data("first".utf8), for: "shared")
        try storage.setKeychainData(Data("any-app secret".utf8), for: "shared", access: .anyApplication)
        #expect(try storage.keychainData(for: "shared") == Data("any-app secret".utf8))

        let found = try #require(
            try security(["find-generic-password", "-w", "-s", storage.keychainService, "-a", "shared", keychain.path]),
            "security waited for the user"
        )
        #expect(found.status == 0, "\(found.output)")
        #expect(found.output == "any-app secret\n")

        try storage.deleteKeychainData(for: "shared")
        #expect(try storage.keychainData(for: "shared") == nil)
    }

    @Test func R09__sdk_is_1_2_after_the_keychain_access_api() {
        #expect(NotchKitSDK.version.supports(SDKVersion(major: 1, minor: 2)))
        #expect(NotchKitSDK.version.supports(SDKVersion(major: 1, minor: 1)))
    }
}
