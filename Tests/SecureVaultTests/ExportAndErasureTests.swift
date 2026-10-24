import XCTest
import UIKit
@testable import SecureVault

final class ExportAndErasureTests: XCTestCase {
    private var root: URL!
    private var paths: VaultDirectories!
    private var defaults: UserDefaults!
    private var suite: String!
    private var keyDeletions = 0
    override func setUpWithError() throws {
        suite = "SecureVaultErasureTests." + UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults = UserDefaults(suiteName: suite)!
        paths = VaultDirectories(documents: root.appendingPathComponent("Documents"), caches: root.appendingPathComponent("Caches"),
            temporary: root.appendingPathComponent("tmp"), support: root.appendingPathComponent("Support"))
        for directory in [paths.documents, paths.caches, paths.temporary, paths.support] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("photo", to: paths.documents.appendingPathComponent("VaultPhotos/1/photo.jpg"))
        try write("metadata", to: paths.documents.appendingPathComponent("VaultPhotos/1/photo.json"))
        try write("diary", to: paths.documents.appendingPathComponent("VaultNotes/notes.json"))
        try write("plain export", to: paths.temporary.appendingPathComponent("export.jpg"))
        try write("cache", to: paths.caches.appendingPathComponent("thumbnail"))
        defaults.set("8765", forKey: "mainCode")
        defaults.set("saved templates", forKey: "labelTemplates")
        defaults.set(Data("event".utf8), forKey: "pendingCaptureEvent")
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func service(destroy: (() throws -> Void)? = nil) -> VaultEraseService {
        VaultEraseService(directories: paths, defaults: defaults, defaultsDomain: suite,
                          destroyKey: destroy ?? { self.keyDeletions += 1 })
    }

    func testPhotosOnlyKeepsDiarySettingsAndKey() throws {
        let erase = service()
        try erase.prepare(.photos, generation: 10)
        try erase.erase(.photos, generation: 10)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.documents.appendingPathComponent("VaultPhotos").path), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.documents.appendingPathComponent("VaultNotes/notes.json").path))
        XCTAssertEqual(defaults.string(forKey: "mainCode"), "8765")
        XCTAssertNil(defaults.data(forKey: "pendingCaptureEvent"))
        XCTAssertEqual(keyDeletions, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.temporary.appendingPathComponent("export.jpg").path))
    }
    func testResetRemovesAllDataAndKeyButDoesNotDisable() throws {
        let erase = service()
        try erase.prepare(.reset, generation: 11)
        try erase.erase(.reset, generation: 11)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.documents.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.caches.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.temporary.path), [])
        XCTAssertNil(defaults.string(forKey: "mainCode"))
        XCTAssertNil(defaults.string(forKey: "labelTemplates"))
        XCTAssertNil(defaults.string(forKey: "pendingEraseMode"))
        XCTAssertFalse(defaults.bool(forKey: "vaultDisabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.disabledMarker.path))
        XCTAssertEqual(defaults.integer(forKey: "vaultGeneration"), 11)
        XCTAssertEqual(keyDeletions, 1)
    }
    func testDisableDeletesMaterialAndReturnsToFreshSetup() throws {
        let erase = service()
        try erase.prepare(.disable, generation: 12)
        // The lock is recorded before any photo is deleted.
        XCTAssertTrue(defaults.bool(forKey: "vaultDisabled"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.disabledMarker.path))
        try erase.erase(.disable, generation: 12)
        XCTAssertFalse(defaults.bool(forKey: "vaultDisabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.disabledMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingMarker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.documents.path), [])
        XCTAssertEqual(keyDeletions, 1)
    }
    func testFailedKeyDeletionKeepsRecoveryRecordAndLock() throws {
        let erase = service(destroy: { throw CocoaError(.fileWriteNoPermission) })
        try erase.prepare(.disable, generation: 13)
        XCTAssertThrowsError(try erase.erase(.disable, generation: 13))
        XCTAssertTrue(defaults.bool(forKey: "vaultDisabled"))
        XCTAssertEqual(defaults.string(forKey: "pendingEraseMode"), "disable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingMarker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.documents.appendingPathComponent("VaultPhotos/1/photo.jpg").path))
    }
    func testResetAfterDisableRemovesBothLocksAndOldCodes() throws {
        var codesDeleted = 0
        let erase = VaultEraseService(directories: paths, defaults: defaults, defaultsDomain: suite,
            destroyKey: { self.keyDeletions += 1 }, destroyCodes: { codesDeleted += 1 })
        // A completed disable from version 1.0 left these two markers behind.
        defaults.set(true, forKey: "vaultDisabled")
        try write("disabled", to: paths.disabledMarker)
        // Simulate material left by another installation before recovery.
        try write("remaining data", to: paths.documents.appendingPathComponent("VaultPhotos/leftover.jpg"))
        try erase.prepare(.reset, generation: 21)
        try erase.erase(.reset, generation: 21)
        XCTAssertFalse(defaults.bool(forKey: "vaultDisabled"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.disabledMarker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingMarker.path))
        XCTAssertNil(defaults.string(forKey: "pendingEraseMode"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.documents.path), [])
        XCTAssertEqual(keyDeletions, 1)
        XCTAssertEqual(codesDeleted, 1)
    }
    func testRecoveryFailureKeepsDisableAndPendingReset() throws {
        defaults.set(true, forKey: "vaultDisabled")
        try write("disabled", to: paths.disabledMarker)
        let failing = service(destroy: { throw CocoaError(.fileWriteNoPermission) })
        try failing.prepare(.reset, generation: 23)
        XCTAssertThrowsError(try failing.erase(.reset, generation: 23))
        XCTAssertTrue(defaults.bool(forKey: "vaultDisabled"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.disabledMarker.path))
        XCTAssertEqual(defaults.string(forKey: "pendingEraseMode"), "reset")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.pendingMarker.path))
    }
    func testNonDestructiveModeCannotErase() throws {
        let erase = service()
        XCTAssertThrowsError(try erase.erase(.camera, generation: 14))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.documents.appendingPathComponent("VaultNotes/notes.json").path))
        XCTAssertEqual(keyDeletions, 0)
    }
    func testOldCallbacksCannotWriteAfterResetReopensGate() throws {
        let gate = VaultGate()
        let old = gate.generation
        XCTAssertEqual(try gate.withAccess(generation: old) { "before" }, "before")
        gate.revoke()
        XCTAssertThrowsError(try gate.withAccess { "during" })
        gate.allow()
        XCTAssertThrowsError(try gate.withAccess(generation: old) { "stale callback" })
        XCTAssertEqual(try gate.withAccess(generation: gate.generation) { "new" }, "new")
    }
    func testDestructiveURLRequiresConfiguredModeAndExactToken() throws {
        let valid = try XCTUnwrap(URL(string: "securevault://action?token=secret"))
        XCTAssertEqual(ActionButtonRouter.resolve(valid, mode: .disable, token: "secret"), .disable)
        XCTAssertNil(ActionButtonRouter.resolve(valid, mode: .off, token: "secret"))
        XCTAssertNil(ActionButtonRouter.resolve(valid, mode: .camera, token: "secret"))
        XCTAssertNil(ActionButtonRouter.resolve(valid, mode: .disable, token: "wrong"))
        XCTAssertNil(ActionButtonRouter.resolve(URL(string: "securevault://action?token=secret&token=secret")!, mode: .disable, token: "secret"))
        XCTAssertNil(ActionButtonRouter.resolve(URL(string: "securevault://camera")!, mode: .photos, token: "secret"))
        XCTAssertEqual(ActionButtonRouter.resolve(URL(string: "securevault://camera")!, mode: .camera, token: nil), .camera)
    }
    func testKeyDeletionInvalidatesOldCiphertextAndAllowsFreshKey() throws {
        let cipher = VaultCipher(service: suite, account: "test-only-key")
        defer { try? cipher.destroyKey() }
        let secret = Data("confidential material".utf8)
        let old = try cipher.encrypt(secret)
        XCTAssertEqual(try cipher.decrypt(old), secret)
        try cipher.destroyKey()
        XCTAssertThrowsError(try cipher.decrypt(old))
        let fresh = try cipher.encrypt(secret)
        XCTAssertEqual(try cipher.decrypt(fresh), secret)
        XCTAssertThrowsError(try cipher.decrypt(old))
    }

    func testCameraKeyRemainsSeparateFromPINBoundVaultKey() throws {
        let service = suite + ".separate-keys"
        let vault = VaultCipher(service: service, account: "vault", pinBindingEnabled: true)
        let camera = VaultCipher(service: service, account: "camera")
        defer { try? vault.destroyKey(); try? camera.destroyKey() }
        let vaultData = try vault.encrypt(Data("vault".utf8))
        let cameraData = try camera.encrypt(Data("camera".utf8))
        try vault.bindPIN("2468")
        let restartedVault = VaultCipher(service: service, account: "vault", pinBindingEnabled: true)
        XCTAssertThrowsError(try restartedVault.decrypt(vaultData))
        try restartedVault.unlock(withPIN: "2468")
        XCTAssertEqual(try restartedVault.decrypt(vaultData), Data("vault".utf8))
        XCTAssertEqual(try camera.decrypt(cameraData), Data("camera".utf8))
    }
    func testExportNoteToggleDoesNotModifyOrDuplicateOriginal() throws {
        let storage = FileStorageManager(directory: root.appendingPathComponent("IsolatedPhotos"), defaults: defaults)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let url = try XCTUnwrap(storage.save(image: image))
        XCTAssertTrue(storage.updateNote(for: url, note: "Место события\nВторая строка"))
        let original = try XCTUnwrap(storage.decryptedData(for: url))
        let epoch = VaultGate.shared.generation
        let plain = try PhotoExporter.jpegData(for: url, includeNotes: false, generation: epoch, storage: storage)
        let annotated = try PhotoExporter.jpegData(for: url, includeNotes: true, generation: epoch, storage: storage)
        let repeated = try PhotoExporter.jpegData(for: url, includeNotes: true, generation: epoch, storage: storage)
        XCTAssertEqual(plain, original)
        let annotatedImage = try XCTUnwrap(UIImage(data: annotated))
        XCTAssertEqual(annotatedImage.size.width, image.size.width)
        XCTAssertEqual(annotatedImage.size.height, image.size.height)
        XCTAssertEqual(UIImage(data: repeated)?.size, annotatedImage.size)
        XCTAssertEqual(storage.decryptedData(for: url), original)
        XCTAssertEqual(storage.loadMeta(for: url)?.note, "Место события\nВторая строка")
    }
    func testLegacyDiaryWithoutPinnedFieldDecodes() throws {
        let legacy: [String: Any] = ["id": UUID().uuidString, "title": "Заголовок", "content": "Текст",
                                   "createdDate": 123.0, "modifiedDate": 124.0]
        let note = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertFalse(note.isPinned)
        XCTAssertEqual(note.content, "Текст")
    }
    func testCorruptDiaryIsNeverOverwrittenByNewNote() throws {
        let directory = paths.documents.appendingPathComponent("VaultNotes")
        let url = directory.appendingPathComponent("notes.json")
        let original = try Data(contentsOf: url)
        let manager = NotesManager(directory: directory)
        XCTAssertFalse(manager.add(title: "Новая", content: "Не должна заменить дневник"))
        XCTAssertNotNil(manager.lastError)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testKnownLegacyCodeNeverUnlocksVault() {
        let previous = SettingsStore.shared.mainCode
        defer { SettingsStore.shared.mainCode = previous }
        SettingsStore.shared.mainCode = "2026"
        let calculator = CalculatorViewModel()
        calculator.tap("2"); calculator.tap("+")
        for digit in "2026" { calculator.tap(String(digit)) }
        calculator.tap("=")
        XCTAssertFalse(calculator.shouldUnlock)
        calculator.tap("AC")
        for digit in "2026" { calculator.tap(String(digit)) }
        calculator.tap("=")
        XCTAssertFalse(calculator.shouldUnlock)
    }
}
