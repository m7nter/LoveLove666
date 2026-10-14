import XCTest
import UIKit
import CoreLocation
@testable import SecureVault

final class StorageAndEditingTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var storage: FileStorageManager!
    private var oldNumbering: String!

    override func setUpWithError() throws {
        suite = "SecureVaultTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        storage = FileStorageManager(directory: directory, defaults: defaults)
        oldNumbering = SettingsStore.shared.numberingMode
        SettingsStore.shared.numberingMode = "both"
    }
    override func tearDownWithError() throws {
        SettingsStore.shared.numberingMode = oldNumbering
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: format).image { _ in
            UIColor.white.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.black.setFill()
            for x in stride(from: 0, to: 200, by: 10) { UIRectFill(CGRect(x: x, y: 0, width: 5, height: 200)) }
        }
    }
    private func event(index: Int = 1, id: UUID = UUID(), date: Date? = nil) -> CaptureContext {
        CaptureContext(eventID: id, folder: "0.5", expectedCount: 3, index: index, eventNumber: 7, capturedAt: date)
    }

    func testSeriesMovesTogetherWithEncryptedSidecars() throws {
        let id = UUID()
        let a = try XCTUnwrap(storage.save(image: image(), context: event(id: id)))
        let b = try XCTUnwrap(storage.save(image: image(), context: event(index: 2, id: id)))
        storage.updateNote(for: a, note: "Источник")
        let raw = try Data(contentsOf: a)
        XCTAssertNil(UIImage(data: raw))
        try storage.moveEvents(containing: [a], to: "2")
        let moved = storage.loadAll()
        XCTAssertEqual(moved.count, 2)
        XCTAssertTrue(moved.allSatisfy { storage.folder(for: $0) == "2" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
        XCTAssertEqual(Set(moved.compactMap { storage.loadMeta(for: $0)?.eventID }), [id])
        XCTAssertTrue(moved.allSatisfy { storage.loadImage(at: $0) != nil })
        XCTAssertTrue(moved.contains { storage.loadMeta(for: $0)?.note == "Источник" })
    }

    func testCollisionRollsBackEntireEvent() throws {
        let id = UUID()
        let a = try XCTUnwrap(storage.save(image: image(), context: event(id: id)))
        let b = try XCTUnwrap(storage.save(image: image(), context: event(index: 2, id: id)))
        let target = directory.appendingPathComponent("2")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: target.appendingPathComponent(a.lastPathComponent))
        XCTAssertThrowsError(try storage.moveEvents(containing: [a], to: "2"))
        XCTAssertNotNil(storage.loadImage(at: a))
        XCTAssertNotNil(storage.loadImage(at: b))
        XCTAssertEqual(storage.loadMeta(for: a)?.folder, "0.5")
        XCTAssertEqual(storage.loadMeta(for: b)?.folder, "0.5")
    }

    func testDailyResetAndMonotonicTotalAfterDeletion() throws {
        let firstDay = Date(timeIntervalSince1970: 1_750_000_000)
        let a = try XCTUnwrap(storage.save(image: image(), context: event(date: firstDay)))
        let b = try XCTUnwrap(storage.save(image: image(), context: event(date: firstDay)))
        XCTAssertEqual(storage.loadMeta(for: a)?.dailyNumber, 1)
        XCTAssertEqual(storage.loadMeta(for: b)?.dailyNumber, 2)
        XCTAssertTrue(storage.delete(url: b))
        let c = try XCTUnwrap(storage.save(image: image(), context: event(date: firstDay.addingTimeInterval(86400))))
        XCTAssertEqual(storage.loadMeta(for: c)?.dailyNumber, 1)
        XCTAssertEqual(storage.loadMeta(for: c)?.totalNumber, 3)
        XCTAssertTrue(storage.exportName(for: c).contains("G000003"))
        XCTAssertEqual(storage.loadMeta(for: c)?.date, firstDay.addingTimeInterval(86400))
    }

    func testLegacyMigrationIsIdempotentAndPreservesNotes() throws {
        let url = directory.appendingPathComponent("old.jpg")
        try XCTUnwrap(image().jpegData(compressionQuality: 0.9)).write(to: url)
        let legacy: [String: Any] = ["latitude": 55.0, "longitude": 37.0,
                                    "date": Date().timeIntervalSinceReferenceDate, "note": "Старая заметка"]
        try JSONSerialization.data(withJSONObject: legacy).write(to: url.deletingPathExtension().appendingPathExtension("json"))
        let reopened = FileStorageManager(directory: directory, defaults: defaults)
        let meta = try XCTUnwrap(reopened.loadMeta(for: url))
        XCTAssertEqual(meta.note, "Старая заметка")
        XCTAssertEqual(meta.totalNumber, 1)
        XCTAssertNotNil(reopened.loadImage(at: url))
        let again = FileStorageManager(directory: directory, defaults: defaults)
        XCTAssertEqual(again.loadMeta(for: url)?.totalNumber, 1)
        XCTAssertEqual(again.folder(for: url), "Без режима")
    }

    func testMissingGPSDoesNotBecomeZeroCoordinatePin() throws {
        let url = try XCTUnwrap(storage.save(image: image(), context: event()))
        XCTAssertEqual(storage.loadMeta(for: url)?.hasLocation, false)
        XCTAssertNil(storage.lastPhotoLocation())
    }

    func testEventSurvivesDayRolloverAndManualCompletion() throws {
        let id = UUID()
        let day = Date(timeIntervalSince1970: 1_750_000_000)
        let a = try XCTUnwrap(storage.save(image: image(), context: event(id: id, date: day)))
        let b = try XCTUnwrap(storage.save(image: image(), context: event(index: 2, id: id, date: day.addingTimeInterval(86400))))
        XCTAssertEqual(storage.eventKey(for: a), storage.eventKey(for: b))
        XCTAssertEqual(storage.loadMeta(for: b)?.dailyNumber, 1)
        storage.completeEvent(id)
        XCTAssertEqual(storage.loadMeta(for: a)?.eventCount, 2)
        XCTAssertEqual(storage.loadMeta(for: b)?.eventCount, 2)
    }

    func testInvalidFolderCannotEscapeStorage() {
        XCTAssertFalse(FileStorageManager.validFolder("../outside"))
        XCTAssertFalse(FileStorageManager.validFolder(".."))
        XCTAssertFalse(FileStorageManager.validFolder("a\\b"))
        XCTAssertTrue(FileStorageManager.validFolder("0.5"))
    }

    func testBrushBlursOnlyPaintedRegionAtFullResolution() throws {
        let source = image()
        let shape = DrawnShape(tool: .blur, start: CGPoint(x: 0.25, y: 0.1), end: CGPoint(x: 0.25, y: 0.9), color: .red,
                               points: [CGPoint(x: 0.25, y: 0.1), CGPoint(x: 0.25, y: 0.9)], width: 0.3)
        let result = AnnotationRenderer.render(image: source, shapes: [shape])
        let baseline = AnnotationRenderer.render(image: source, shapes: [])
        XCTAssertEqual(result.size, source.size)
        func crop(_ image: UIImage, x: CGFloat) throws -> Data {
            let cg = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: x, y: 80, width: 10, height: 10)))
            return try XCTUnwrap(UIImage(cgImage: cg).pngData())
        }
        XCTAssertNotEqual(try crop(baseline, x: 45), try crop(result, x: 45))
        XCTAssertEqual(try crop(baseline, x: 160), try crop(result, x: 160))
    }

    func testCorruptCiphertextIsNotExportedAsAnImage() throws {
        let url = directory.appendingPathComponent("broken.jpg")
        try Data([1, 2, 3, 4, 5]).write(to: url)
        XCTAssertNil(storage.decryptedData(for: url))
    }
}
