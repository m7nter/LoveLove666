import XCTest

final class RestrictedPlacesRadarUITests: XCTestCase {
    func testRadarShowsCameraSnapshotAndCanBeClosedWithoutChangingCalculatorAccess() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-calculator", "--preview-radar", "-AppleLocale", "ru_RU"]
        app.launch()
        XCTAssertTrue(app.staticTexts["radar.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["radar.status"].exists)
        XCTAssertTrue(app.staticTexts["radar.source"].label.contains("OSM онлайн"))
        XCTAssertTrue(app.buttons["radar.recenter"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "radar.legend").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "radar.details").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Ожидаем координаты"].exists)
        XCTAssertNotEqual(app.staticTexts["radar.distance"].label, "—")
        app.buttons["radar.recenter"].tap()
        XCTAssertTrue(app.staticTexts["radar.range"].label.contains("500"))
        let overlay = app.descendants(matching: .any).matching(identifier: "radar.debug.overlay").firstMatch
        let allMarkers = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "4"), object: overlay)
        XCTAssertEqual(XCTWaiter.wait(for: [allMarkers], timeout: 10), .completed)
        app.descendants(matching: .any).matching(identifier: "radar.map").firstMatch.pinch(withScale: 2, velocity: 1)
        app.buttons["radar.recenter"].tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "4"), object: overlay)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Restricted-places-radar"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["radar.close"].tap()
        XCTAssertTrue(app.buttons["calculator.menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["access.code"].exists)
        XCTAssertFalse(app.buttons["access.reset"].exists)
    }
}
