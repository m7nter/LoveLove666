import Foundation

protocol PINChangeStore {
    func read(_ account: String) throws -> String
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

struct KeychainPINChangeStore: PINChangeStore {
    func read(_ account: String) throws -> String { try KeychainCodeStore.readChecked(account) }
    func write(_ value: String, account: String) throws { try KeychainCodeStore.write(value, for: account) }
    func delete(_ account: String) throws { try KeychainCodeStore.delete(account) }
}

/// A recoverable transaction across the PIN envelope and the access-code item.
/// The journal has the same device-only Keychain protection as mainCode. It is
/// written before changing either item and destroyed by every full reset.
struct MainPINChangeTransaction {
    static let journalAccount = "pendingMainPINChange"
    private struct Journal: Codable {
        let oldPIN: String
        let newPIN: String
    }
    let store: PINChangeStore
    let unlock: (String) throws -> Void
    let bind: (String) throws -> Void

    static var application: MainPINChangeTransaction {
        MainPINChangeTransaction(store: KeychainPINChangeStore(),
            unlock: { pin in try VaultGate.shared.withAccess { try CryptoManager.unlock(withPIN: pin) } },
            bind: { pin in try VaultGate.shared.withAccess { try CryptoManager.rebindPIN(pin) } })
    }

    func recoverIfNeeded() throws {
        let value = try store.read(Self.journalAccount)
        guard !value.isEmpty else { return }
        guard let data = value.data(using: .utf8),
              let journal = try? JSONDecoder().decode(Journal.self, from: data),
              valid(journal.oldPIN), valid(journal.newPIN) else { throw CocoaError(.fileReadCorruptFile) }
        let committed = try store.read("mainCode")
        guard committed == journal.oldPIN || committed == journal.newPIN else { throw CocoaError(.fileReadCorruptFile) }
        do { try unlock(committed) }
        catch {
            let alternate = committed == journal.oldPIN ? journal.newPIN : journal.oldPIN
            try unlock(alternate)
            try bind(committed)
            try unlock(committed)
        }
        // Both authoritative items now agree. A failed cleanup can be retried
        // on the next launch without preventing access or changing the PIN.
        try? store.delete(Self.journalAccount)
    }

    func change(to newPIN: String) throws {
        guard valid(newPIN) else { throw CocoaError(.fileWriteUnknown) }
        try recoverIfNeeded()
        let oldPIN = try store.read("mainCode")
        guard valid(oldPIN) else { throw CocoaError(.fileReadCorruptFile) }
        try unlock(oldPIN)
        let data = try JSONEncoder().encode(Journal(oldPIN: oldPIN, newPIN: newPIN))
        guard let value = String(data: data, encoding: .utf8) else { throw CocoaError(.fileWriteUnknown) }
        try store.write(value, account: Self.journalAccount)
        do {
            try bind(newPIN)
            try store.write(newPIN, account: "mainCode")
        } catch {
            // If only one write succeeded, reconcile to the code that actually
            // persisted. If recovery also fails, retain the durable journal.
            try recoverIfNeeded()
            throw error
        }
        try? store.delete(Self.journalAccount)
    }

    private func valid(_ pin: String) -> Bool {
        (4...8).contains(pin.count) && pin.allSatisfy { "0123456789".contains($0) }
    }
}
