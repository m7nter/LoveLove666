import Foundation
import Combine

struct Note: Codable, Identifiable {
    let id: UUID
    var title: String
    var content: String
    var createdDate: Date
    var modifiedDate: Date
    var isPinned: Bool = false
    init(id: UUID, title: String, content: String, createdDate: Date, modifiedDate: Date, isPinned: Bool = false) {
        self.id = id; self.title = title; self.content = content
        self.createdDate = createdDate; self.modifiedDate = modifiedDate; self.isPinned = isPinned
    }
    private enum CodingKeys: String, CodingKey { case id, title, content, createdDate, modifiedDate, isPinned }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        createdDate = try c.decode(Date.self, forKey: .createdDate)
        modifiedDate = try c.decode(Date.self, forKey: .modifiedDate)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

final class NotesManager: ObservableObject {
    static let shared = NotesManager()
    @Published var lastError: String?
    private let fileURL: URL
    init(directory: URL? = nil) {
        fileURL = (directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VaultNotes")).appendingPathComponent("notes.json")
    }
    private func read() throws -> [Note] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        try? (fileURL as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
        let raw = try Data(contentsOf: fileURL)
        if let decrypted = CryptoManager.decrypt(raw) {
            return try JSONDecoder().decode([Note].self, from: decrypted)
        }
        // Migrate legacy unencrypted diaries before exposing their contents.
        let legacy = try JSONDecoder().decode([Note].self, from: raw)
        guard let encrypted = CryptoManager.encrypt(raw) else { throw CocoaError(.fileWriteUnknown) }
        try encrypted.write(to: fileURL, options: [.atomic, .completeFileProtection])
        return legacy
    }
    func migrateLegacyIfNeeded() {
        try? VaultGate.shared.withAccess { _ = try read() }
    }
    func loadAll() -> [Note] {
        do { return try VaultGate.shared.withAccess { try read() } }
        catch { lastError = "Не удалось прочитать дневник: \(error.localizedDescription)"; return [] }
    }
    private func change(generation: Int?, _ body: (inout [Note]) -> Void) -> Bool {
        do {
            try VaultGate.shared.withAccess(generation: generation) {
                var notes = try read() // Never overwrite a corrupt/unreadable diary with an empty one.
                body(&notes)
                guard let encrypted = CryptoManager.encrypt(try JSONEncoder().encode(notes)) else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? (fileURL.deletingLastPathComponent() as NSURL).setResourceValue(URLFileProtection.complete, forKey: .fileProtectionKey)
                try encrypted.write(to: fileURL, options: [.atomic, .completeFileProtection])
            }
            return true
        } catch { lastError = "Заметки не сохранены: \(error.localizedDescription)"; return false }
    }
    @discardableResult func add(title: String, content: String, generation: Int? = nil) -> Bool {
        change(generation: generation) { notes in
            notes.insert(Note(id: UUID(), title: title, content: content, createdDate: Date(), modifiedDate: Date()), at: 0)
        }
    }
    @discardableResult func update(_ note: Note, generation: Int? = nil) -> Bool {
        change(generation: generation) { notes in
            if let index = notes.firstIndex(where: { $0.id == note.id }) {
                var updated = note; updated.modifiedDate = Date(); notes[index] = updated
            }
        }
    }
    @discardableResult func togglePin(_ note: Note) -> Bool {
        change(generation: nil) { notes in
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index].isPinned.toggle() }
        }
    }
    @discardableResult func delete(_ note: Note) -> Bool {
        change(generation: nil) { $0.removeAll { $0.id == note.id } }
    }
}
