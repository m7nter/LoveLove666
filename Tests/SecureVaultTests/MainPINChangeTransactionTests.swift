import XCTest
@testable import SecureVault

private final class MemoryPINChangeStore: PINChangeStore {
    var values = ["mainCode": "2468"]
    var failWriteAccount: String?
    var failDeletes = false
    func read(_ account: String) throws -> String { values[account] ?? "" }
    func write(_ value: String, account: String) throws {
        if account == failWriteAccount { throw CocoaError(.fileWriteNoPermission) }
        values[account] = value
    }
    func delete(_ account: String) throws {
        guard !failDeletes else { throw CocoaError(.fileWriteNoPermission) }
        values.removeValue(forKey: account)
    }
}

final class MainPINChangeTransactionTests: XCTestCase {
    private var store: MemoryPINChangeStore!
    private var envelopePIN = "2468"
    private var failBindPIN: String?
    override func setUp() {
        store = MemoryPINChangeStore(); envelopePIN = "2468"; failBindPIN = nil
    }
    private func transaction() -> MainPINChangeTransaction {
        MainPINChangeTransaction(store: store, unlock: { pin in
            guard pin == self.envelopePIN else { throw CocoaError(.fileReadNoPermission) }
        }, bind: { pin in
            guard pin != self.failBindPIN else { throw CocoaError(.fileWriteNoPermission) }
            self.envelopePIN = pin
        })
    }
    private func seedJournal() throws {
        let data = try JSONSerialization.data(withJSONObject: ["oldPIN": "2468", "newPIN": "8642"])
        store.values[MainPINChangeTransaction.journalAccount] = String(data: data, encoding: .utf8)
    }
    func testSuccessfulChangeCommitsBothItemsAndRemovesJournal() throws {
        try transaction().change(to: "8642")
        XCTAssertEqual(store.values["mainCode"], "8642")
        XCTAssertEqual(envelopePIN, "8642")
        XCTAssertNil(store.values[MainPINChangeTransaction.journalAccount])
    }
    func testJournalWriteFailureLeavesBothOriginalItemsUntouched() {
        store.failWriteAccount = MainPINChangeTransaction.journalAccount
        XCTAssertThrowsError(try transaction().change(to: "8642"))
        XCTAssertEqual(store.values["mainCode"], "2468")
        XCTAssertEqual(envelopePIN, "2468")
        XCTAssertNil(store.values[MainPINChangeTransaction.journalAccount])
    }
    func testEnvelopeFailureDoesNotChangeAccessCode() {
        failBindPIN = "8642"
        XCTAssertThrowsError(try transaction().change(to: "8642"))
        XCTAssertEqual(store.values["mainCode"], "2468")
        XCTAssertEqual(envelopePIN, "2468")
    }
    func testCodeWriteFailureRollsBackEnvelopeToThePersistedOldCode() {
        store.failWriteAccount = "mainCode"
        XCTAssertThrowsError(try transaction().change(to: "8642"))
        XCTAssertEqual(store.values["mainCode"], "2468")
        XCTAssertEqual(envelopePIN, "2468")
        XCTAssertNil(store.values[MainPINChangeTransaction.journalAccount])
    }
    func testRestartBeforeEnvelopeWriteKeepsOldPIN() throws {
        try seedJournal()
        try transaction().recoverIfNeeded()
        XCTAssertEqual(envelopePIN, "2468")
        XCTAssertEqual(store.values["mainCode"], "2468")
        XCTAssertNil(store.values[MainPINChangeTransaction.journalAccount])
    }
    func testRestartBetweenEnvelopeAndCodeWritesRollsBackSafely() throws {
        try seedJournal(); envelopePIN = "8642"
        try transaction().recoverIfNeeded()
        XCTAssertEqual(envelopePIN, "2468")
        XCTAssertEqual(store.values["mainCode"], "2468")
        XCTAssertNil(store.values[MainPINChangeTransaction.journalAccount])
    }
    func testRestartAfterBothWritesKeepsNewPIN() throws {
        try seedJournal(); envelopePIN = "8642"; store.values["mainCode"] = "8642"
        try transaction().recoverIfNeeded()
        XCTAssertEqual(envelopePIN, "8642")
        XCTAssertEqual(store.values["mainCode"], "8642")
        XCTAssertNil(store.values[MainPINChangeTransaction.journalAccount])
    }
    func testRecoveryFailureRetainsJournalForTheNextLaunch() throws {
        try seedJournal(); envelopePIN = "8642"; failBindPIN = "2468"
        XCTAssertThrowsError(try transaction().recoverIfNeeded())
        XCTAssertNotNil(store.values[MainPINChangeTransaction.journalAccount])
        XCTAssertEqual(store.values["mainCode"], "2468")
        failBindPIN = nil
        try transaction().recoverIfNeeded()
        XCTAssertEqual(envelopePIN, "2468")
    }
    func testUnknownCodeOrCorruptJournalNeverReplacesTheEnvelope() throws {
        try seedJournal(); store.values["mainCode"] = "1357"
        XCTAssertThrowsError(try transaction().recoverIfNeeded())
        XCTAssertEqual(envelopePIN, "2468")
        XCTAssertNotNil(store.values[MainPINChangeTransaction.journalAccount])
        store.values[MainPINChangeTransaction.journalAccount] = "corrupt"
        XCTAssertThrowsError(try transaction().recoverIfNeeded())
        XCTAssertEqual(envelopePIN, "2468")
    }
    func testCleanupFailureDoesNotReportACommittedPINChangeAsFailure() throws {
        store.failDeletes = true
        try transaction().change(to: "8642")
        XCTAssertEqual(store.values["mainCode"], "8642")
        XCTAssertEqual(envelopePIN, "8642")
        XCTAssertNotNil(store.values[MainPINChangeTransaction.journalAccount])
        store.failDeletes = false
        try transaction().recoverIfNeeded()
        XCTAssertNil(store.values[MainPINChangeTransaction.journalAccount])
    }
}
