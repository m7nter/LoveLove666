import XCTest
@testable import SecureVault

private final class MemoryInactivityStateStore: InactivityStateStore {
    var values: [String: Data] = [:]
    var failsWrites = false
    var writes = 0
    func read(_ account: String) throws -> Data? { values[account] }
    func write(_ data: Data, account: String) throws {
        guard !failsWrites else { throw CocoaError(.fileWriteNoPermission) }
        values[account] = data; writes += 1
    }
    func delete(_ account: String) throws { values.removeValue(forKey: account) }
}

final class InactivityPersistenceTests: XCTestCase {
    private var store: MemoryInactivityStateStore!
    private var wall: TimeInterval = 1_000_000
    private var uptime: TimeInterval = 10_000
    override func setUp() {
        store = MemoryInactivityStateStore()
        wall = 1_000_000; uptime = 10_000
    }
    private func manager() -> InactivityTimerManager {
        InactivityTimerManager(store: store, wallClock: { self.wall }, uptimeClock: { self.uptime })
    }
    private func advance(_ seconds: TimeInterval) { wall += seconds; uptime += seconds }
    private func seedLegacy(hours: Int) {
        store.values["limitHours"] = Data(String(hours).utf8)
        store.values["lastWallClock"] = Data(String(wall).utf8)
        store.values["lastSystemUptime"] = Data(String(uptime).utf8)
    }

    func testFailedActivationKeepsPreviousModeAndOriginalDeadlineAcrossRestart() {
        let timer = manager()
        XCTAssertTrue(timer.activate(hours: 24))
        let previous = store.values
        advance(23 * 3600)
        store.failsWrites = true
        XCTAssertFalse(timer.activate(hours: 168))
        XCTAssertEqual(timer.limitHours, 24)
        XCTAssertEqual(store.values, previous)
        XCTAssertNotNil(timer.lastError)
        let restarted = manager()
        XCTAssertEqual(restarted.limitHours, 24)
        XCTAssertFalse(restarted.shouldWipeData(limitHours: 24))
        advance(3600)
        XCTAssertTrue(restarted.shouldWipeData(limitHours: 24))
    }

    func testFailedInitialActivationDoesNotPretendItWasEnabled() {
        store.failsWrites = true
        let timer = manager()
        XCTAssertFalse(timer.activate(hours: 24))
        XCTAssertFalse(timer.isEnabled)
        XCTAssertTrue(store.values.isEmpty)
        XCTAssertEqual(manager().limitHours, 0)
    }

    func testFailedActivityWritePreservesBothPreviousClocks() {
        let timer = manager()
        XCTAssertTrue(timer.activate(hours: 24))
        let previous = store.values
        advance(23 * 3600)
        store.failsWrites = true
        XCTAssertFalse(timer.recordActivity())
        XCTAssertEqual(store.values, previous)
        XCTAssertFalse(timer.shouldWipeData(limitHours: 24))
        advance(3600)
        XCTAssertTrue(manager().shouldWipeData(limitHours: 24))
    }

    func testFailedDisableKeepsProtectionEnabledInMemoryAndOnDisk() {
        let timer = manager()
        XCTAssertTrue(timer.activate(hours: 48))
        let previous = store.values
        store.failsWrites = true
        timer.disable()
        XCTAssertTrue(timer.isEnabled)
        XCTAssertEqual(timer.limitHours, 48)
        XCTAssertEqual(store.values, previous)
        XCTAssertEqual(manager().limitHours, 48)
        XCTAssertNotNil(timer.lastError)
    }

    func testLegacyProtectionMigratesOnlyAfterSuccessfulActivity() {
        seedLegacy(hours: 72)
        let timer = manager()
        XCTAssertEqual(timer.limitHours, 72)
        XCTAssertNil(store.values["state.v2"])
        advance(3600)
        store.failsWrites = true
        XCTAssertFalse(timer.recordActivity())
        XCTAssertNil(store.values["state.v2"])
        XCTAssertEqual(manager().limitHours, 72)
        store.failsWrites = false
        XCTAssertTrue(timer.recordActivity())
        XCTAssertNotNil(store.values["state.v2"])
        advance(71 * 3600)
        XCTAssertFalse(manager().shouldWipeData(limitHours: 72))
        advance(3600)
        XCTAssertTrue(manager().shouldWipeData(limitHours: 72))
    }

    func testDisabledRecordDoesNotResurrectLegacyModeAfterRestart() {
        seedLegacy(hours: 24)
        let timer = manager()
        timer.disable()
        XCTAssertFalse(timer.isEnabled)
        XCTAssertEqual(manager().limitHours, 0)
        store.values["limitHours"] = Data("24".utf8)
        XCTAssertNotNil(store.values["limitHours"])
        advance(48 * 3600)
        XCTAssertFalse(manager().shouldWipeData(limitHours: 0))
    }

    func testExpiredTimerCannotBeRefreshedByOpeningVault() {
        let timer = manager()
        XCTAssertTrue(timer.activate(hours: 24))
        let writes = store.writes
        advance(24 * 3600)
        XCTAssertFalse(timer.recordActivity())
        XCTAssertEqual(store.writes, writes)
        XCTAssertTrue(manager().shouldWipeData(limitHours: 24))
    }

    func testClearMarkersKeepsEnabledModeAndFailsClosedAfterRestart() {
        let timer = manager()
        XCTAssertTrue(timer.activate(hours: 48))
        timer.clearMarkers()
        let restarted = manager()
        XCTAssertEqual(restarted.limitHours, 48)
        XCTAssertTrue(restarted.shouldWipeData(limitHours: 48))
    }

    func testEverySelectableIntervalExpiresExactlyAtDeadlineAfterRestart() {
        for hours in [24, 48, 72, 168] {
            store = MemoryInactivityStateStore()
            let timer = manager()
            XCTAssertTrue(timer.activate(hours: hours))
            advance(Double(hours) * 3600 - 1)
            XCTAssertFalse(manager().shouldWipeData(limitHours: hours))
            advance(1)
            XCTAssertTrue(manager().shouldWipeData(limitHours: hours))
        }
    }

    func testClockToleranceBoundaryAndNegativeUptimeFailClosed() {
        XCTAssertFalse(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 100_000, savedUptime: 1_000, currentWall: 100_000, currentUptime: 1_600))
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 100_000, savedUptime: 1_000, currentWall: 100_000, currentUptime: 1_600.001))
        XCTAssertTrue(InactivityTimerManager.shouldWipeData(limitHours: 24,
            savedWall: 100_000, savedUptime: 1_000, currentWall: 100_001, currentUptime: -1))
    }
}
