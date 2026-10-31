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
        assertPosition(app, "1 из 2")
        keepScreenshot("Event-gallery")
        let second = photos.element(boundBy: 1)
        let secondFilename = String(second.identifier.dropFirst("event.photo.".count))
        second.tap()
        assertPosition(app, "2 из 2")
        let secondPage = app.buttons["event.open." + secondFilename]
        XCTAssertTrue(secondPage.isHittable)
        secondPage.swipeRight()
        assertPosition(app, "1 из 2")
        second.tap()
        assertPosition(app, "2 из 2")
        app.buttons["event.openCurrent"].tap()
        let detailPosition = app.staticTexts["photo.detail.position"]
        XCTAssertTrue(detailPosition.waitForExistence(timeout: 10))
        XCTAssertEqual(detailPosition.label, "2 из 2")
        XCTAssertTrue(app.buttons["photo.detail.edit"].exists)
        app.swipeRight()
        let fullScreenPage = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "1 из 2"), object: detailPosition)
        XCTAssertEqual(XCTWaiter.wait(for: [fullScreenPage], timeout: 5), .completed)
        app.buttons["photo.detail.close"].tap()
        assertPosition(app, "1 из 2")
    }
    func testSelectingEventDeletesAllItsFramesAndKeepsNeighbour() {
        let app = launch(["--test-gallery"])
        for key in ["1", "3", "5", "7", "="] { app.buttons["calculator.key." + key].tap() }
        XCTAssertTrue(app.buttons["Папки"].waitForExistence(timeout: 10)); app.buttons["Папки"].tap()
        let folder = app.buttons.containing(NSPredicate(format: "label BEGINSWITH '0.5'")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10)); folder.tap()
        let event = app.buttons["gallery.event.12345678-1234-1234-1234-123456789012"]
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["gallery.folderTitle"].label, "0.5")
        app.buttons["gallery.select"].tap()
        event.tap()
        XCTAssertEqual(app.staticTexts["gallery.selectionSummary"].label, "Выбрано: 1 событие · 2 фото")
        keepScreenshot("Event-selection")
        app.buttons["gallery.deleteSelected"].tap()
        XCTAssertTrue(app.alerts["Удалить 1 событие?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Удалить"].tap()
        let deleted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: event)
        XCTAssertEqual(XCTWaiter.wait(for: [deleted], timeout: 10), .completed)
        XCTAssertTrue(app.buttons["gallery.event.22345678-1234-1234-1234-123456789012"].exists)
        XCTAssertEqual(app.staticTexts["gallery.summary"].label, "1 событие · 1 фото")
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
    func testRestrictionSettingsCanBeEnabledAndShowDefaultBoundaryRadius() {
        let app = launch()
        for key in ["1", "3", "5", "7", "="] { app.buttons["calculator.key." + key].tap() }
        XCTAssertTrue(app.buttons["Папки"].waitForExistence(timeout: 10)); app.buttons["Папки"].tap()
        let settings = app.buttons["gallery.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["settings.category.location"].waitForExistence(timeout: 10))
        app.buttons["settings.category.location"].tap()
        let territories = app.buttons["settings.restrictedPlaces"]
        for _ in 0..<8 { if territories.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(territories.isHittable); territories.tap()
        let enabled = app.switches["settings.restrictedPlaces.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        if enabled.value as? String == "0" { enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap() }
        if app.alerts.firstMatch.waitForExistence(timeout: 2) { app.alerts.buttons["Позже"].tap() }
        XCTAssertEqual(enabled.value as? String, "1")
        keepScreenshot("Restricted-places-settings")
        let radius = app.steppers["settings.restrictedPlaces.radius.playground"]
        for _ in 0..<4 { if radius.exists { break }; app.swipeUp() }
        XCTAssertTrue(radius.exists)
        XCTAssertEqual(radius.value as? String, "65")
        keepScreenshot("Restricted-places-distances")
        for _ in 0..<4 { if enabled.isHittable { break }; app.swipeDown() }
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }
    func testOfflineRegionCanBeChosenManuallyWithoutDownloading() {
        let app = launch()
        for key in ["1", "3", "5", "7", "="] { app.buttons["calculator.key." + key].tap() }
        XCTAssertTrue(app.buttons["Папки"].waitForExistence(timeout: 10)); app.buttons["Папки"].tap()
        XCTAssertTrue(app.buttons["gallery.settings"].waitForExistence(timeout: 10)); app.buttons["gallery.settings"].tap()
        XCTAssertTrue(app.buttons["settings.category.location"].waitForExistence(timeout: 10))
        app.buttons["settings.category.location"].tap()
        let territories = app.buttons["settings.restrictedPlaces"]
        for _ in 0..<8 { if territories.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(territories.isHittable); territories.tap()
        let offline = app.buttons["settings.offlineMaps"]
        // The iOS 26 Form can place this section below the fold; keep
        // scrolling until the link is actually hittable instead of relying on
        // a fixed number of swipes.
        for _ in 0..<12 { if offline.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(offline.isHittable); offline.tap()
        let search = app.textFields["offline.regionSearch"]
        for _ in 0..<4 { if search.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(search.isHittable); search.tap(); search.typeText("RU-MOS")
        let region = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'offline.region.'")).firstMatch
        XCTAssertTrue(region.waitForExistence(timeout: 5)); region.tap()
        keepScreenshot("Offline-region-selection")
        XCTAssertTrue(region.isSelected)
    }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--test-calculator"] + extra; app.launch()
        XCTAssertTrue(app.buttons["calculator.menu"].waitForExistence(timeout: 10))
        return app
    }
    private func assertPosition(_ app: XCUIApplication, _ expected: String) {
        let position = app.staticTexts["event.position"]
        let matching = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [matching], timeout: 5), .completed)
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
