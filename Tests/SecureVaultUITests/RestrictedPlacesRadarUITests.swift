import XCTest

final class RestrictedPlacesRadarUITests: XCTestCase {
    func testRadarShowsCameraSnapshotAndCanBeClosedWithoutChangingCalculatorAccess() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--test-calculator", "--preview-radar"]
        app.launch()
        XCTAssertTrue(app.staticTexts["radar.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["radar.status"].exists)
        XCTAssertTrue(app.buttons["radar.recenter"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "radar.legend").firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "radar.details").firstMatch.exists)
        app.buttons["radar.recenter"].tap()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Restricted-places-radar"; screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["radar.close"].tap()
        XCTAssertTrue(app.buttons["calculator.menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["access.code"].exists)
        XCTAssertFalse(app.buttons["access.reset"].exists)
    }
}
