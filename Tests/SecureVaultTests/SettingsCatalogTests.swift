import XCTest
@testable import SecureVault

final class SettingsCatalogTests: XCTestCase {
    func testRussianSearchRecognizesYoAndCaseAndRejectsPunctuation() {
        XCTAssertTrue(SettingsCatalog.search("ЧЕРНЫЙ ЭКРАН").contains { $0.id == .blackScreen })
        XCTAssertTrue(SettingsCatalog.search("чёрный экран").contains { $0.id == .blackScreen })
        XCTAssertTrue(SettingsCatalog.search(" ?! ").isEmpty)
    }

    func testMultiwordSearchFindsSpecificControlsInsteadOfUnrelatedCategoryMatches() {
        XCTAssertEqual(SettingsCatalog.search("только координаты").map(\.id), [.archiveMetadata])
        XCTAssertEqual(SettingsCatalog.search("фон GPS").map(\.id), [.continuousGPS])
        XCTAssertEqual(SettingsCatalog.search("аватарка").map(\.id), [.avatar])
        XCTAssertEqual(SettingsCatalog.search("Два касания тремя пальцами").map(\.id), [.blackScreen])
        XCTAssertEqual(SettingsCatalog.search("Стереть данные и заблокировать вход").map(\.id), [.actionButton])
    }

    func testSearchRoutesToDownloadsOrExactSecurityAndCameraSection() {
        XCTAssertEqual(SettingsCatalog.search("скачать регион").first?.destination, .offlineMaps)
        XCTAssertEqual(SettingsCatalog.search("5 попыток").first?.destination, .category(.security, focus: .bruteForce))
        XCTAssertEqual(SettingsCatalog.search("громкости").first?.destination, .category(.camera, focus: .volumeCapture))
    }
}
