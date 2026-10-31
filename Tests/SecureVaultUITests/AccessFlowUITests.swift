import XCTest

final class AccessFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System permission") { alert in
            let whileUsing = alert.buttons["Allow While Using App"]
            if whileUsing.exists { whileUsing.tap() }
            else { alert.buttons.element(boundBy: 0).tap() }
            return true
        }
    }

    func testResetInstallAutomaticallyPromptsForPINAndPersistsIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-legacy-lock"]
        app.launch()
        // The reset fixture simulates an installation which needs a new PIN.
        // Setup must be presented automatically, without a hidden recovery
        // gesture or a way to destroy an existing vault from the calculator.
        createVault(app, code: "4826")
        dismissWelcomeIfPresented(app)
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

    func testLongPressDoesNotExposeRecoveryOrResetAndPINStillWorks() {
        let app = XCUIApplication()
        app.launchArguments = ["--test-calculator"]
        app.launch()
        let menu = app.buttons["calculator.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertFalse(app.buttons["Хранилище"].exists)
        XCTAssertFalse(app.staticTexts["Калькулятор 1.1.0 (3)"].exists)
        app.tapCoordinate(x: 0.08, y: 0.40)
        let display = app.staticTexts["calculator.display"]
        XCTAssertTrue(display.waitForExistence(timeout: 10))
        display.press(forDuration: 3.2)
        XCTAssertFalse(app.secureTextFields["access.code"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["access.reset"].exists)
        XCTAssertFalse(app.staticTexts["Настройка доступа"].exists)
        XCTAssertTrue(app.buttons["calculator.menu"].exists)
        for key in ["AC", "1", "3", "5", "7", "="] {
            XCTAssertTrue(app.buttons["calculator.key." + key].waitForExistence(timeout: 10))
            app.buttons["calculator.key." + key].tap()
        }
        XCTAssertTrue(app.staticTexts["Хранилище"].waitForExistence(timeout: 10))
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertFalse(app.secureTextFields["access.confirmation"].exists)
        for key in ["AC", "1", "3", "5", "7", "="] {
            XCTAssertTrue(app.buttons["calculator.key." + key].waitForExistence(timeout: 10))
            app.buttons["calculator.key." + key].tap()
        }
        XCTAssertTrue(app.staticTexts["Хранилище"].waitForExistence(timeout: 10))
    }

    func testFooterAvatarSurvivesPINMigrationAndProcessTermination() {
        // This scenario intentionally launches two real app processes. The
        // first simulator automation handshake can consume 40+ seconds alone.
        executionTimeAllowance = 180
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
        let choosePhoto = app.buttons["Выбрать фото"]
        // Settings uses a virtualised List. Full-screen swipes can skip the
        // entire avatar row and reach the bottom before AX instantiates it.
        // Stop on the real row control, then check the image and its model-
        // dependent delete action; do not mistake an offscreen row for loss.
        for _ in 0..<16 {
            if choosePhoto.isHittable { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.54))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(choosePhoto.isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Footer-avatar-after-unlock"; screenshot.lifetime = .keepAlways
        add(screenshot)
        let avatar = app.descendants(matching: .any).matching(identifier: "settings.footerAvatar").firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Удалить"].exists,
                      "The delete control exists only while the decoded saved avatar is present")
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
        XCTAssertFalse(app.buttons["access.reset"].exists)
        if !submit.isHittable { app.swipeUp() }
        submit.tap()
    }

    private func dismissWelcomeIfPresented(_ app: XCUIApplication) {
        let experienced = app.buttons["welcome.skipGuide"]
        if experienced.waitForExistence(timeout: 5) { experienced.tap() }
    }
}

private extension XCUIApplication {
    func tapCoordinate(x: CGFloat, y: CGFloat) {
        coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).tap()
    }
}
