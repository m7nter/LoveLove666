import XCTest
@testable import SecureVault

final class InactivityTimerTests: XCTestCase {
    func testIntervalDoesNotWipeBeforeDeadline() {
        XCTAssertFalse(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 1_000, savedUptime: 500, currentWall: 1_000 + 23 * 3600,
            currentUptime: 500 + 23 * 3600))
    }

    func testIntervalWipesAtDeadlineUsingEitherClock() {
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 1_000, savedUptime: 500, currentWall: 1_000 + 24 * 3600,
            currentUptime: 500 + 24 * 3600))
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 1_000, savedUptime: 500, currentWall: 1_000 + 23 * 3600,
            currentUptime: 500 + 24 * 3600))
    }

    func testWallClockRollbackIsDetectedAgainstUptime() {
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 168,
            savedWall: 10_000, savedUptime: 2_000, currentWall: 10_000 - 601,
            currentUptime: 2_000 + 601))
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 168,
            savedWall: 10_000, savedUptime: 2_000, currentWall: 10_000 + 100,
            currentUptime: 2_000 + 701))
    }

    func testRebootUsesWallClockAfterUptimeReset() {
        XCTAssertFalse(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 10_000, savedUptime: 20_000, currentWall: 10_000 + 23 * 3600,
            currentUptime: 5))
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 10_000, savedUptime: 20_000, currentWall: 10_000 + 24 * 3600,
            currentUptime: 5))
    }

    func testInvalidClockValuesFailClosed() {
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: .nan, savedUptime: 1, currentWall: 2, currentUptime: 3))
        XCTAssertFalse(InactivityTimerManager.shouldWipeData(limitHours: 0,
            savedWall: .nan, savedUptime: .nan, currentWall: .nan, currentUptime: .nan))
    }
}
