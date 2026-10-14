import XCTest
import UIKit
import CoreLocation
import ImageIO
import ZIPFoundation
@testable import SecureVault

final class ExportMetadataTests: XCTestCase {
    private func record(_ index: Int, located: Bool = true) -> ExportPhotoRecord {
        var meta = PhotoMeta(latitude: 55.7777777 + Double(index), longitude: 67.7777777,
                             date: Date(timeIntervalSince1970: 0), hasLocation: located)
        meta.note = "private note"; meta.eventNumber = 99; meta.eventIndex = index + 1
        meta.eventCount = 2; meta.dailyNumber = 123; meta.totalNumber = 456
        return .init(filename: "photo-\(index + 1).jpg", meta: meta, folder: "private folder")
    }
    func testCoordinatesOnlyDoesNotIncludeOtherFields() throws {
        let text = try XCTUnwrap(ExportMetadata.archiveText([record(0), record(1, located: false)], options: .coordinates))
        XCTAssertEqual(text, "1) 55.7777777, 67.7777777\n2) нет данных\n")
        for hidden in ["private", "1970", "99", "123", "456", "photo-", "https"] { XCTAssertFalse(text.contains(hidden)) }
    }
    func testSelectedFieldsAreIndependentAndNoneOmitsFile() throws {
        let dateOnly = try XCTUnwrap(ExportMetadata.archiveText([record(0)], options: .date))
        XCTAssertTrue(dateOnly.contains("Дата съёмки:"))
        XCTAssertFalse(dateOnly.contains("Координаты:")); XCTAssertFalse(dateOnly.contains("private"))
        let notesAndFolder = try XCTUnwrap(ExportMetadata.archiveText([record(0)], options: [.notes, .folder]))
        XCTAssertTrue(notesAndFolder.contains("private note")); XCTAssertTrue(notesAndFolder.contains("private folder"))
        XCTAssertFalse(notesAndFolder.contains("Дата")); XCTAssertFalse(notesAndFolder.contains("Координаты"))
        XCTAssertNil(ExportMetadata.archiveText([record(0)], options: []))
    }
    func testMessageTimeAttachmentOrderAndMissingLocation() {
        let text = ExportMetadata.coordinateMessage([record(1, located: false), record(0)],
            exportedAt: Date(timeIntervalSince1970: 80940), timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertEqual(text, "Выгрузка 22:29. Координаты:\n1) нет данных\n2) 55.7777777, 67.7777777")
    }
    func testLegacyUnknownAndInvalidCoordinatesDoNotInventGPS() {
        XCTAssertNil(ExportMetadata.coordinates(.init(latitude: 0, longitude: 0, date: Date())))
        XCTAssertNotNil(ExportMetadata.coordinates(.init(latitude: 0, longitude: 0, date: Date(), hasLocation: true)))
        XCTAssertNil(ExportMetadata.coordinates(.init(latitude: 99, longitude: 0, date: Date(), hasLocation: true)))
        XCTAssertNil(ExportMetadata.coordinates(nil))
    }
    func testLargeCoordinateExportSplitsIntoCompleteLines() {
        let text = ExportMetadata.coordinateMessage((0..<500).map { _ in record(0) })
        let parts = ExportMetadata.messageParts(text)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 3800 })
        XCTAssertEqual(parts.joined(separator: "\n"), text)
    }
    func testZipCoordinatesOnlyKeepsAspectAndOmitsEmbeddedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); PhotoExporter.cleanupTemporaryExports() }
        let storage = FileStorageManager(directory: root)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { _ in
            UIColor.red.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let photo = try XCTUnwrap(storage.save(image: image, location: CLLocation(latitude: 55.7777777, longitude: 67.7777777)))
        XCTAssertTrue(storage.updateNote(for: photo, note: "private note"))
        let zip = try XCTUnwrap(ZipExporter.exportDay(label: "Coordinates", urls: [photo], includeNotes: true,
                                                     metadata: .coordinates, storage: storage))
        let archive = try Archive(url: zip, accessMode: .read)
        XCTAssertEqual(Set(archive.map(\.path)), Set(["photo-0001.jpg", "metadata.txt"]))
        var text = Data(), jpeg = Data()
        _ = try archive.extract(XCTUnwrap(archive["metadata.txt"])) { text.append($0) }
        _ = try archive.extract(XCTUnwrap(archive["photo-0001.jpg"])) { jpeg.append($0) }
        XCTAssertEqual(String(data: text, encoding: .utf8), "1) 55.7777777, 67.7777777\n")
        XCTAssertEqual(UIImage(data: jpeg)?.size, image.size)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertTrue((properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]).isEmpty)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        for key in ["DateTimeOriginal", "DateTimeDigitized", "UserComment", "LensMake", "LensModel"] { XCTAssertNil(exif[key]) }
        for key in ["Make", "Model", "Artist", "DateTime", "ImageDescription"] { XCTAssertNil(tiff[key]) }
        let noMetadataZip = try XCTUnwrap(ZipExporter.exportDay(label: "No metadata", urls: [photo], metadata: [], storage: storage))
        let plainArchive = try Archive(url: noMetadataZip, accessMode: .read)
        XCTAssertNil(plainArchive["metadata.txt"])
    }
    func testEventCoverIsFirstFrameAndLegacyPhotosRemainSeparate() {
        let folder = "0.5", event = UUID()
        var first = record(0).meta!, second = record(1).meta!
        first.eventID = event; first.eventIndex = 1
        second.eventID = event; second.eventIndex = 2
        let a = URL(fileURLWithPath: "/a.jpg"), b = URL(fileURLWithPath: "/b.jpg"), c = URL(fileURLWithPath: "/c.jpg")
        let records: [GalleryRecord] = [
            .init(url: b, meta: second, date: Date(timeIntervalSince1970: 20), folder: folder, eventKey: event.uuidString),
            .init(url: c, meta: nil, date: Date(timeIntervalSince1970: 30), folder: folder, eventKey: c.path),
            .init(url: a, meta: first, date: Date(timeIntervalSince1970: 10), folder: folder, eventKey: event.uuidString)
        ]
        let groups = GalleryGrouping.events(records)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.urls, [c])
        XCTAssertEqual(groups.last?.urls, [a, b])
        XCTAssertEqual(GalleryGrouping.days(groups).flatMap(\.urls).count, 3)
    }
    func testWatermarkEditorAndNotePreservePortraitAndLandscapePixels() throws {
        for size in [CGSize(width: 400, height: 300), CGSize(width: 300, height: 400)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIColor.blue.setFill(); UIRectFill(CGRect(origin: .zero, size: size))
            }
            let marked = WatermarkRenderer.apply(to: image, location: nil, heading: nil)
            let edited = AnnotationRenderer.render(image: marked, shapes: [])
            let noted = try ExportNoteRenderer.apply(to: edited, note: "Проверка")
            for result in [marked, edited, noted] {
                XCTAssertEqual(result.size, image.size)
                XCTAssertEqual(result.cgImage?.width, image.cgImage?.width)
                XCTAssertEqual(result.cgImage?.height, image.cgImage?.height)
            }
        }
    }
    func testSanitizedLegacyJPEGDoesNotRetainGPSDateOrCameraIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { _ in
            UIColor.blue.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        let attributes: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.7, kCGImagePropertyGPSLatitudeRef: "N",
                                          kCGImagePropertyGPSLongitude: 67.7, kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06", kCGImagePropertyExifUserComment: "private comment"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "private camera", kCGImagePropertyTIFFArtist: "private owner"]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), attributes as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let photo = root.appendingPathComponent("legacy.jpg")
        try (data as Data).write(to: photo)
        let storage = FileStorageManager(directory: root)
        let sanitized = try PhotoExporter.jpegData(for: photo, includeNotes: false,
            generation: VaultGate.shared.generation, storage: storage, stripEmbeddedMetadata: true)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(sanitized as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        XCTAssertTrue((properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] ?? [:]).isEmpty)
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        XCTAssertNil(exif["DateTimeOriginal"]); XCTAssertNil(exif["UserComment"])
        XCTAssertNil(tiff["Make"]); XCTAssertNil(tiff["Artist"])
        XCTAssertEqual(UIImage(data: sanitized)?.size, image.size)
        XCTAssertFalse(sanitized == data as Data)
    }
}
