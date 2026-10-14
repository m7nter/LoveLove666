import XCTest

final class CalculatorAndGalleryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            alert.buttons.element(boundBy: 0).tap(); return true
        }
    }
    func testPublicCalculatorMenuHasNoVaultOrVersion() {
        let app = launch()
        XCTAssertFalse(app.staticTexts["Хранилище"].exists)
        XCTAssertFalse(app.secureTextFields["access.code"].exists)
        app.buttons["calculator.menu"].tap()
        XCTAssertTrue(app.buttons["Стандартный"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Хранилище"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '1.1.'")).firstMatch.exists)
        keepScreenshot("Calculator-menu")
    }
    func testConversionPickerHasHorizontalCategoriesAndSearch() {
        let app = launch(["--preview-units"])
        XCTAssertTrue(app.staticTexts["Единицы"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Валюта"].exists)
        XCTAssertTrue(app.buttons["Площадь"].exists)
        let search = app.textFields["conversion.search"]
        XCTAssertTrue(search.exists)
        keepScreenshot("Calculator-units")
        search.tap(); search.typeText("EUR")
        let euro = app.buttons["conversion.unit.EUR"]
        XCTAssertTrue(euro.waitForExistence(timeout: 5)); euro.tap()
        XCTAssertTrue(app.staticTexts["calculator.converted"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Frankfurter'")).firstMatch.exists)
    }
    func testEventCoverOpensItsTwoPhotosWithoutMixingEvents() {
        let app = launch(["--test-gallery"])
        for key in ["1", "3", "5", "7", "="] { app.buttons["calculator.key." + key].tap() }
        XCTAssertTrue(app.buttons["Папки"].waitForExistence(timeout: 10))
        app.buttons["Папки"].tap()
        let folder = app.buttons.containing(NSPredicate(format: "label BEGINSWITH '0.5'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.tap()
        let event = app.descendants(matching: .any).matching(identifier: "gallery.event.12345678-1234-1234-1234-123456789012").firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        keepScreenshot("Event-cover")
        event.tap()
        let photos = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'event.photo.'"))
        XCTAssertTrue(photos.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(photos.count, 2)
        keepScreenshot("Event-gallery")
    }
    func testPressedButtonVisualFeedback() {
        let app = launch()
        keepScreenshot("Calculator-before-press")
        let capture = HeldScreenshot()
        let ready = expectation(description: "Screenshot during real button press")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) {
            capture.set(XCUIScreen.main.screenshot()); ready.fulfill()
        }
        app.buttons["calculator.key.8"].press(forDuration: 1.2)
        wait(for: [ready], timeout: 5)
        let attachment = XCTAttachment(screenshot: capture.get()!)
        attachment.name = "Calculator-during-press"; attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--test-calculator"] + extra; app.launch()
        XCTAssertTrue(app.buttons["calculator.menu"].waitForExistence(timeout: 10))
        return app
    }
    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private final class HeldScreenshot: @unchecked Sendable {
    private let lock = NSLock()
    private var image: XCUIScreenshot?
    func set(_ value: XCUIScreenshot) { lock.lock(); image = value; lock.unlock() }
    func get() -> XCUIScreenshot? { lock.lock(); defer { lock.unlock() }; return image }
}
