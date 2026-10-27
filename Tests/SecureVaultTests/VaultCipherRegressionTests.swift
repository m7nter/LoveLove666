import XCTest
import UIKit
import Security
@testable import SecureVault

final class VaultCipherRegressionTests: XCTestCase {
    private var service: String!
    private let account = "test-master"
    private var notifications: NotificationCenter!

    override func setUp() {
        service = "SecureVaultCipherRegression." + UUID().uuidString
        notifications = NotificationCenter()
    }

    override func tearDown() {
        try? cipher().destroyKey()
    }

    private func cipher(bound: Bool = true, clearsOnBackground: Bool = true) -> VaultCipher {
        VaultCipher(service: service, account: account, pinBindingEnabled: bound,
                    clearsOnBackground: clearsOnBackground, notificationCenter: notifications)
    }

    private func rawKeyStatus() -> OSStatus {
        SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service!,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ] as CFDictionary, nil)
    }

    func testLockedBoundVaultNeverCreatesReplacementMasterKey() throws {
        let original = cipher()
        let payload = Data("original photo and settings".utf8)
        let encrypted = try original.encrypt(payload)
        try original.bindPIN("2468")
        original.lockKey()

        for _ in 0..<3 {
            XCTAssertThrowsError(try original.encrypt(Data("must not save with a new key".utf8)))
            XCTAssertThrowsError(try original.decrypt(encrypted))
            XCTAssertEqual(rawKeyStatus(), errSecItemNotFound)
        }
        let restarted = cipher()
        XCTAssertThrowsError(try restarted.encrypt(payload))
        try restarted.unlock(withPIN: "2468")
        XCTAssertEqual(try restarted.decrypt(encrypted), payload)
        XCTAssertEqual(try restarted.decrypt(restarted.encrypt(payload)), payload)
        XCTAssertEqual(rawKeyStatus(), errSecItemNotFound)
    }

    func testExplicitLockClearsKeyAndWrongPINCannotReopenIt() throws {
        let vault = cipher()
        let data = try vault.encrypt(Data("secret".utf8))
        try vault.bindPIN("2468")
        vault.lockKey()
        XCTAssertThrowsError(try vault.unlock(withPIN: "1111"))
        XCTAssertThrowsError(try vault.decrypt(data))
        XCTAssertThrowsError(try vault.encrypt(Data("secret".utf8)))
        try vault.unlock(withPIN: "2468")
        XCTAssertEqual(try vault.decrypt(data), Data("secret".utf8))
    }

    func testGracePeriodKeepsAuthenticatedKeyUntilActualLock() throws {
        let vault = cipher(clearsOnBackground: false)
        let before = try vault.encrypt(Data("before".utf8))
        try vault.bindPIN("2468")
        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let after = try vault.encrypt(Data("after".utf8))
        XCTAssertEqual(try vault.decrypt(before), Data("before".utf8))
        let restarted = cipher()
        try restarted.unlock(withPIN: "2468")
        XCTAssertEqual(try restarted.decrypt(after), Data("after".utf8))
        XCTAssertEqual(rawKeyStatus(), errSecItemNotFound)
        vault.lockKey()
        XCTAssertThrowsError(try vault.encrypt(Data("locked".utf8)))
    }

    func testProtectedDeviceLockAlwaysPurgesGracePeriodKey() throws {
        let vault = cipher(clearsOnBackground: false)
        let data = try vault.encrypt(Data("secret".utf8))
        try vault.bindPIN("2468")
        notifications.post(name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        XCTAssertThrowsError(try vault.decrypt(data))
        XCTAssertThrowsError(try vault.encrypt(Data("locked".utf8)))
        try vault.unlock(withPIN: "2468")
        XCTAssertEqual(try vault.decrypt(data), Data("secret".utf8))
    }

    func testDefaultBackgroundPolicyClearsKey() throws {
        let vault = cipher()
        let data = try vault.encrypt(Data("secret".utf8))
        try vault.bindPIN("2468")
        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertThrowsError(try vault.decrypt(data))
        XCTAssertThrowsError(try vault.encrypt(Data("locked".utf8)))
    }

    func testRecoversOldAccidentalKeyOnlyAfterCorrectPINAndAcrossRebind() throws {
        let vault = cipher()
        let canonical = try vault.encrypt(Data("original master".utf8))
        try vault.bindPIN("2468")
        vault.lockKey()

        // Reproduce the old release: it incorrectly stored a new raw key next
        // to the PIN envelope and wrote new photos/preferences with that key.
        let legacyBug = cipher(bound: false)
        let affected = try legacyBug.encrypt(Data("affected photo".utf8))
        XCTAssertEqual(rawKeyStatus(), errSecSuccess)
        let restarted = cipher()
        XCTAssertThrowsError(try restarted.decrypt(affected))
        XCTAssertThrowsError(try restarted.unlock(withPIN: "1111"))
        XCTAssertEqual(rawKeyStatus(), errSecSuccess)
        try restarted.unlock(withPIN: "2468")
        XCTAssertEqual(rawKeyStatus(), errSecItemNotFound)
        XCTAssertEqual(try restarted.decrypt(canonical), Data("original master".utf8))
        XCTAssertEqual(try restarted.decrypt(affected), Data("affected photo".utf8))

        restarted.lockKey()
        XCTAssertThrowsError(try restarted.decrypt(affected))
        try restarted.unlock(withPIN: "2468")
        try restarted.bindPIN("8642")
        restarted.lockKey()
        XCTAssertThrowsError(try restarted.unlock(withPIN: "2468"))
        try restarted.unlock(withPIN: "8642")
        XCTAssertEqual(try restarted.decrypt(canonical), Data("original master".utf8))
        XCTAssertEqual(try restarted.decrypt(affected), Data("affected photo".utf8))
        try restarted.destroyKey()
        XCTAssertThrowsError(try restarted.decrypt(canonical))
        XCTAssertThrowsError(try restarted.decrypt(affected))
    }

    func testCameraCipherRemainsUsableAfterItsCacheIsCleared() throws {
        let camera = cipher(bound: false)
        let data = try camera.encrypt(Data("camera-only".utf8))
        camera.lockKey()
        XCTAssertEqual(try camera.decrypt(data), Data("camera-only".utf8))
        XCTAssertEqual(try camera.decrypt(camera.encrypt(Data("new photo".utf8))), Data("new photo".utf8))
    }
}
