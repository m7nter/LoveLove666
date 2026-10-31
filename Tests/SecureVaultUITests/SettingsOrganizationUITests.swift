import XCTest

final class SettingsOrganizationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            let whileUsing = alert.buttons["Allow While Using App"]
            if whileUsing.exists { whileUsing.tap() }
            else { alert.buttons.element(boundBy: 0).tap() }
            return true
        }
    }

    func testSearchOpensControlAndSettingSurvivesRealProcessRelaunch() {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["--test-calculator", "--test-settings"]
        app.launch()
        openSettings(app)
        keepScreenshot("Settings-home")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("громкости")
        let result = app.buttons["settings.search.volumeCapture"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        keepScreenshot("Settings-search")
        result.tap()
        let toggle = app.switches["settings.volumeCapture"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertTrue(toggle.isHittable)
        let original = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let changed = toggle.value as? String
        XCTAssertNotEqual(original, changed)
        keepScreenshot("Settings-camera")
        app.terminate()

        app.launchArguments = []
        app.launch()
        openSettings(app)
        app.buttons["settings.category.camera"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, changed)
        // Restore the original non-destructive preference after verification.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, original)
    }

    func testSearchingDestructiveSettingsStillRequiresConfirmationAndCancelChangesNothing() {
        executionTimeAllowance = 180
        let app = XCUIApplication()
        app.launchArguments = ["--test-calculator", "--test-settings"]
        app.launch()
        openSettings(app)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("неактивности")
        let result = app.buttons["settings.search.inactivity"]
        XCTAssertTrue(result.waitForExistence(timeout: 5)); result.tap()
        let enabled = app.switches["settings.inactivityEnabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertTrue(enabled.isHittable, "Search must reveal the requested section without manual scrolling")
        XCTAssertEqual(enabled.value as? String, "0")
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let confirm = app.buttons["security.inactivity.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); XCTAssertFalse(confirm.isEnabled)
        cancelWarning(app, identifier: "security.inactivity.cancel")
        XCTAssertEqual(enabled.value as? String, "0")

        let attempts = app.buttons["settings.failedPasswordWipeLimit"]
        for _ in 0..<4 { if attempts.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(attempts.isHittable); attempts.tap()
        let five = app.buttons["5 попыток"]
        XCTAssertTrue(five.waitForExistence(timeout: 5)); five.tap()
        let bruteConfirm = app.buttons["security.bruteForce.confirm"]
        XCTAssertTrue(bruteConfirm.waitForExistence(timeout: 5)); XCTAssertFalse(bruteConfirm.isEnabled)
        cancelWarning(app, identifier: "security.bruteForce.cancel")
        XCTAssertTrue(attempts.label.contains("Выключено") || (attempts.value as? String) == "Выключено")
        keepScreenshot("Settings-security")
    }

    private func openSettings(_ app: XCUIApplication) {
        for key in ["AC", "1", "3", "5", "7", "="] {
            let button = app.buttons["calculator.key." + key]
            XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        }
        XCTAssertTrue(app.buttons["Папки"].waitForExistence(timeout: 10)); app.buttons["Папки"].tap()
        let settings = app.buttons["gallery.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        XCTAssertTrue(app.buttons["settings.guide"].waitForExistence(timeout: 10))
    }

    private func cancelWarning(_ app: XCUIApplication, identifier: String) {
        let cancel = app.buttons[identifier]
        for _ in 0..<5 { if cancel.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(cancel.isHittable); XCTAssertTrue(cancel.isEnabled); cancel.tap()
    }

    private func keepScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
