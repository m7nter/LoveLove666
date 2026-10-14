import Foundation
import ZIPFoundation

struct ZipExporter {
    static func exportDay(label: String, urls: [URL], includeNotes: Bool = false, generation: Int? = nil,
                          numberingMode: String? = nil, metadata: ArchiveMetadataOptions = .standard,
                          storage: FileStorageManager = .shared) -> URL? {
        guard !urls.isEmpty else { return nil }
        let fm = FileManager.default
        let epoch = generation ?? VaultGate.shared.generation
        guard let exportDir = try? PhotoExporter.makeTemporaryExportDirectory(generation: epoch) else { return nil }
        let workDir = exportDir.appendingPathComponent("photos", isDirectory: true)
        let safeLabel = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let zipURL = exportDir.appendingPathComponent((metadata.contains(.date) ? String(safeLabel.prefix(100)) : "Снимки") + ".zip")
        do {
            try PhotoExporter.createProtectedDirectory(at: workDir, generation: epoch)
            var records: [ExportPhotoRecord] = []
            for (index, url) in urls.enumerated() {
                // Filenames must not disclose metadata the user excluded.
                let filename = String(format: "photo-%04d.jpg", index + 1)
                let data = try PhotoExporter.jpegData(for: url, includeNotes: includeNotes && metadata.contains(.notes),
                    generation: epoch, storage: storage, stripEmbeddedMetadata: true)
                try VaultGate.shared.withAccess(generation: epoch) {
                    try data.write(to: workDir.appendingPathComponent(filename), options: [.atomic, .completeFileProtection])
                    records.append(ExportPhotoRecord(filename: filename, meta: storage.loadMeta(for: url), folder: storage.folder(for: url)))
                }
            }
            if let text = ExportMetadata.archiveText(records, options: metadata) {
                try VaultGate.shared.withAccess(generation: epoch) {
                    try Data(text.utf8).write(to: workDir.appendingPathComponent("metadata.txt"), options: [.atomic, .completeFileProtection])
                }
            }
            let archive = try VaultGate.shared.withAccess(generation: epoch) { try Archive(url: zipURL, accessMode: .create) }
            let contents = try VaultGate.shared.withAccess(generation: epoch) { try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) }
            for fileURL in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try VaultGate.shared.withAccess(generation: epoch) { try archive.addEntry(with: fileURL.lastPathComponent, relativeTo: workDir) }
            }
            try VaultGate.shared.withAccess(generation: epoch) {
                try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: zipURL.path)
            }
            try? fm.removeItem(at: workDir)
            return try VaultGate.shared.withAccess(generation: epoch) { zipURL }
        } catch {
            try? fm.removeItem(at: exportDir)
            return nil
        }
    }
}
