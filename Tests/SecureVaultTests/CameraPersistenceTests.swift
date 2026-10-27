import XCTest
import UIKit
@testable import SecureVault

final class CameraPersistenceTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var vault: VaultCipher!
    private var camera: VaultCipher!

    override func setUpWithError() throws {
        suite = "CameraPersistenceTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        vault = VaultCipher(service: suite, account: "vault", pinBindingEnabled: true)
        camera = VaultCipher(service: suite, account: "camera")
    }

    override func tearDownWithError() throws {
        try? vault.destroyKey()
        try? camera.destroyKey()
        defaults.removePersistentDomain(forName: suite)
    }

    // Independent Keychain accounts exercise real encryption without changing
    // the running test host's master key or its PIN.
    private func store(vault: VaultCipher? = nil, camera: VaultCipher? = nil) -> ProtectedPreferenceStore {
        let vault = vault ?? self.vault!
        let camera = camera ?? self.camera!
        return ProtectedPreferenceStore(defaults: defaults,
            encryptVault: { data in (try? vault.encrypt(data)).map { Data([0]) + $0 } },
            encryptCamera: { data in (try? camera.encrypt(data)).map { Data([1]) + $0 } },
            decrypt: { data in
                guard let purpose = data.first else { return nil }
                let cipher = purpose == 1 ? camera : vault
                return try? cipher.decrypt(Data(data.dropFirst()))
            },
            isCameraEncrypted: { $0.first == 1 })
    }

    private func imageData() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30), format: format).image { _ in
            UIColor.orange.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
    }

    func testLegacyAvatarSurvivesLockedColdStartAndMigratesAfterUnlock() throws {
        let image = try imageData()
        let original = Data([0]) + (try vault.encrypt(image))
        defaults.set(original, forKey: "protected.userAvatar")
        try vault.bindPIN("2468")
        vault.lockKey()

        let settings = SettingsStore(protectedPreferences: store())
        XCTAssertNil(settings.avatarImage)
        XCTAssertEqual(defaults.data(forKey: "protected.userAvatar"), original,
                       "Launching before PIN entry must not delete an unreadable avatar")

        try vault.unlock(withPIN: "2468")
        settings.reloadProtectedPreferences()
        XCTAssertEqual(settings.avatarImage?.size, CGSize(width: 40, height: 30))
        XCTAssertEqual(defaults.data(forKey: "protected.userAvatar")?.first, 1)
        XCTAssertNil(defaults.data(forKey: "userAvatar"))

        vault.lockKey(); camera.lockKey()
        let restartedVault = VaultCipher(service: suite, account: "vault", pinBindingEnabled: true)
        let restartedCamera = VaultCipher(service: suite, account: "camera")
        let reopened = SettingsStore(protectedPreferences: store(vault: restartedVault, camera: restartedCamera))
        XCTAssertEqual(reopened.avatarImage?.size, CGSize(width: 40, height: 30),
                       "Camera-only launch after force quit must retain the configured footer image")
        XCTAssertThrowsError(try restartedVault.decrypt(Data(original.dropFirst())))
    }

    func testAvatarSelectedWhileVaultIsLockedIsEncryptedAndPersists() throws {
        _ = try vault.encrypt(Data("initialize".utf8))
        try vault.bindPIN("2468")
        vault.lockKey()
        let settings = SettingsStore(protectedPreferences: store())
        settings.avatarImage = try XCTUnwrap(UIImage(data: imageData()))
        let saved = try XCTUnwrap(defaults.data(forKey: "protected.userAvatar"))
        XCTAssertEqual(saved.first, 1)
        XCTAssertNil(UIImage(data: saved))
        XCTAssertNil(defaults.object(forKey: "userAvatar"))
        camera.lockKey()
        XCTAssertNotNil(SettingsStore(protectedPreferences: store()).avatarImage)
    }

    func testTemplatesAndPendingEventSurviveCameraOnlyRestartButHistoryStaysPINBound() throws {
        let preferences = store()
        XCTAssertTrue(preferences.set("Под камнем", forKey: "selectedTemplate"))
        XCTAssertTrue(preferences.set(["Под камнем", "У дерева"], forKey: "labelTemplates"))
        let context = CaptureContext(eventID: UUID(), folder: "0.5", expectedCount: 2, index: 2, eventNumber: 7)
        let event = try JSONEncoder().encode(context)
        XCTAssertTrue(preferences.set(event, forKey: "pendingCaptureEvent"))
        XCTAssertTrue(preferences.set(Data("history".utf8), forKey: "calculator.history.v2"))
        try vault.bindPIN("2468")
        vault.lockKey(); camera.lockKey()

        let reopened = store()
        XCTAssertEqual(reopened.string(forKey: "selectedTemplate"), "Под камнем")
        XCTAssertEqual(reopened.stringArray(forKey: "labelTemplates"), ["Под камнем", "У дерева"])
        let resumed = try JSONDecoder().decode(CaptureContext.self, from: XCTUnwrap(reopened.data(forKey: "pendingCaptureEvent")))
        XCTAssertEqual(resumed.eventID, context.eventID)
        XCTAssertEqual(resumed.index, 2)
        XCTAssertNil(reopened.data(forKey: "calculator.history.v2"))
        try vault.unlock(withPIN: "2468")
        XCTAssertEqual(reopened.data(forKey: "calculator.history.v2"), Data("history".utf8))
    }

    func testUnavailableEncryptionPreservesPreviousAvatarAndReportsFailure() throws {
        let previous = try imageData()
        XCTAssertTrue(store().set(previous, forKey: "userAvatar"))
        let ciphertext = defaults.data(forKey: "protected.userAvatar")
        let unavailable = ProtectedPreferenceStore(defaults: defaults,
            encryptVault: { _ in nil }, encryptCamera: { _ in nil },
            decrypt: { _ in nil }, isCameraEncrypted: { _ in true })
        XCTAssertFalse(unavailable.set(Data("replacement".utf8), forKey: "userAvatar"))
        XCTAssertEqual(defaults.data(forKey: "protected.userAvatar"), ciphertext)
        XCTAssertNil(defaults.object(forKey: "userAvatar"))
        let settings = SettingsStore(protectedPreferences: unavailable)
        settings.avatarImage = try XCTUnwrap(UIImage(data: previous))
        XCTAssertNotNil(settings.avatarError)
        XCTAssertNil(settings.avatarImage, "A failed write must not pretend the replacement was saved")
        XCTAssertEqual(defaults.data(forKey: "protected.userAvatar"), ciphertext)
    }

    func testLegacyPlaintextOnlyRemovedAfterEncryptedCopyCanBeWritten() throws {
        let original = try imageData()
        defaults.set(original, forKey: "userAvatar")
        let unavailable = ProtectedPreferenceStore(defaults: defaults,
            encryptVault: { _ in nil }, encryptCamera: { _ in nil },
            decrypt: { _ in nil }, isCameraEncrypted: { _ in false })
        XCTAssertEqual(unavailable.data(forKey: "userAvatar"), original)
        XCTAssertEqual(defaults.data(forKey: "userAvatar"), original)
        XCTAssertNil(defaults.object(forKey: "protected.userAvatar"))
        XCTAssertEqual(store().data(forKey: "userAvatar"), original)
        XCTAssertNil(defaults.object(forKey: "userAvatar"))
        XCTAssertEqual(defaults.data(forKey: "protected.userAvatar")?.first, 1)
    }

    func testRemoveAllClearsBothCameraAndVaultPreferences() throws {
        let preferences = store()
        XCTAssertTrue(preferences.set(try imageData(), forKey: "userAvatar"))
        XCTAssertTrue(preferences.set("label", forKey: "selectedTemplate"))
        XCTAssertTrue(preferences.set(Data("history".utf8), forKey: "calculator.history.v2"))
        defaults.set("keep", forKey: "unrelated")
        preferences.removeAll()
        XCTAssertNil(defaults.object(forKey: "protected.userAvatar"))
        XCTAssertNil(defaults.object(forKey: "protected.selectedTemplate"))
        XCTAssertNil(defaults.object(forKey: "protected.calculator.history.v2"))
        XCTAssertEqual(defaults.string(forKey: "unrelated"), "keep")
    }
}
