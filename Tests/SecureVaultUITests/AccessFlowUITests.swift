import XCTest

final class AccessFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            alert.buttons.element(boundBy: 0).tap()
            return true
        }
    }

    func testLegacyDisabledInstallCanCreateVaultLockAndUnlockAgain() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-legacy-lock"]
        app.launch()
        openHiddenAccess(app)
        createVault(app, code: "4826")
        XCTAssertTrue(app.staticTexts["Хранилище"].waitForExistence(timeout: 10))
        app.buttons["Калькулятор"].tap()
        for key in ["AC", "4", "8", "2", "6", "="] {
            XCTAssertTrue(app.buttons["calculator.key." + key].waitForExistence(timeout: 5))
            app.buttons["calculator.key." + key].tap()
        }
        XCTAssertTrue(app.staticTexts["Хранилище"].waitForExistence(timeout: 5))
        app.terminate()

        // Relaunch without the fixture: the persisted code must still work.
        app.launchArguments = []
        app.launch()
        for key in ["AC", "4", "8", "2", "6", "="] {
            XCTAssertTrue(app.buttons["calculator.key." + key].waitForExistence(timeout: 5))
            app.buttons["calculator.key." + key].tap()
        }
        XCTAssertTrue(app.staticTexts["Хранилище"].waitForExistence(timeout: 5))
    }

    func testResetIsAvailableEvenWhenOldCodeSurvives() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-calculator"]
        app.launch()
        let menu = app.buttons["calculator.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertFalse(app.buttons["Хранилище"].exists)
        XCTAssertFalse(app.staticTexts["Калькулятор 1.1.0 (3)"].exists)
        app.tapCoordinate(x: 0.08, y: 0.40)
        openHiddenAccess(app)
        app.buttons["access.reset"].tap()
        app.alerts.buttons["Удалить и создать заново"].tap()
        openHiddenAccess(app)
        createVault(app, code: "5804")
        XCTAssertTrue(app.staticTexts["Хранилище"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []
        app.launch()
        for key in ["AC", "5", "8", "0", "4", "="] {
            XCTAssertTrue(app.buttons["calculator.key." + key].waitForExistence(timeout: 10))
            app.buttons["calculator.key." + key].tap()
        }
        XCTAssertTrue(app.staticTexts["Хранилище"].waitForExistence(timeout: 10))
    }

    func testFooterAvatarSurvivesPINMigrationAndProcessTermination() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-calculator", "--test-legacy-avatar"]
        app.launch()
        unlockAndCheckFooterAvatar(app)
        app.terminate()

        // The second process receives no seeding flag and uses only the
        // persisted keychain/preferences left by the preceding real unlock.
        app.launchArguments = []
        app.launch()
        unlockAndCheckFooterAvatar(app)
    }

    private func unlockAndCheckFooterAvatar(_ app: XCUIApplication) {
        for key in ["AC", "1", "3", "5", "7", "="] {
            let button = app.buttons["calculator.key." + key]
            XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
        }
        let gallery = app.buttons["Папки"]
        XCTAssertTrue(gallery.waitForExistence(timeout: 10)); gallery.tap()
        let settings = app.buttons["gallery.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let avatar = app.images["settings.footerAvatar"]
        for _ in 0..<6 {
            if avatar.exists { break }
            app.swipeUp()
        }
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
    }

    private func createVault(_ app: XCUIApplication, code: String) {
        let confirmation = app.secureTextFields["access.confirmation"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 20))
        let first = app.secureTextFields["access.code"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        first.tap(); first.typeText(code)
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.tap(); confirmation.typeText(code)
        let submit = app.buttons["access.submit"]
        if !submit.isHittable { app.swipeUp() }
        submit.tap()
    }
    private func openHiddenAccess(_ app: XCUIApplication) {
        let display = app.staticTexts["calculator.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 20))
        display.press(forDuration: 3.2)
    }
}

private extension XCUIApplication {
    func tapCoordinate(x: CGFloat, y: CGFloat) {
        coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
}
