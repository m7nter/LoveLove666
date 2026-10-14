import Foundation
import ZIPFoundation

struct ZipExporter {
    static func exportDay(label: String, urls: [URL], includeNotes: Bool = false, generation: Int? = nil, numberingMode: String? = nil) -> URL? {
        guard !urls.isEmpty else { return nil }

        let fm = FileManager.default
        let epoch = generation ?? VaultGate.shared.generation
        guard let exportDir = try? PhotoExporter.makeTemporaryExportDirectory(generation: epoch) else { return nil }
        let workDir = exportDir.appendingPathComponent("photos", isDirectory: true)
        let safeLabel = label.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let zipURL = exportDir.appendingPathComponent(String(safeLabel.prefix(100)) + ".zip")

        do {
            try PhotoExporter.createProtectedDirectory(at: workDir, generation: epoch)

            var metadataLines: [String] = []
            metadataLines.append("Экспорт фото — \(label)")
            metadataLines.append("Всего снимков: \(urls.count)")
            metadataLines.append("")

            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "ru_RU")
            dateFormatter.dateFormat = "d MMMM yyyy, HH:mm:ss"

            for url in urls {
                let filename = FileStorageManager.shared.exportName(for: url, numberingMode: numberingMode)
                let destURL = workDir.appendingPathComponent(filename)
                let decrypted = try PhotoExporter.jpegData(for: url, includeNotes: includeNotes, generation: epoch)
                try VaultGate.shared.withAccess(generation: epoch) {
                    try decrypted.write(to: destURL, options: [.atomic, .completeFileProtection])
                }

                if let meta = FileStorageManager.shared.loadMeta(for: url) {
                    let dateStr = dateFormatter.string(from: meta.date)
                    metadataLines.append("Файл: \(filename)")
                    metadataLines.append("Папка: \(FileStorageManager.shared.folder(for: url))")
                    metadataLines.append("Событие: \(meta.eventNumber.map(String.init) ?? "отдельный снимок")")
                    metadataLines.append("Кадр: \(meta.eventIndex ?? 1) / \(meta.eventCount ?? 1)")
                    metadataLines.append("Координаты: \(meta.hasLocation == false ? "нет данных" : String(format: "%.6f, %.6f", meta.latitude, meta.longitude))")
                    metadataLines.append("Карта: \(meta.hasLocation == false ? "нет данных" : "https://maps.google.com/?q=\(meta.latitude),\(meta.longitude)")")
                    metadataLines.append("Дата съёмки: \(dateStr)")
                    if includeNotes, let note = meta.note, !note.isEmpty { metadataLines.append("Заметка: \(note)") }
                    metadataLines.append("")
                } else {
                    metadataLines.append("""
                    Файл: \(filename)
                    Координаты: нет данных

                    """)
                }
            }

            let metaFileURL = workDir.appendingPathComponent("metadata.txt")
            try VaultGate.shared.withAccess(generation: epoch) {
                try Data(metadataLines.joined(separator: "\n").utf8)
                    .write(to: metaFileURL, options: [.atomic, .completeFileProtection])
            }
            let archive = try VaultGate.shared.withAccess(generation: epoch) { try Archive(url: zipURL, accessMode: .create) }
            let contents = try VaultGate.shared.withAccess(generation: epoch) { try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil) }
            for fileURL in contents {
                try VaultGate.shared.withAccess(generation: epoch) { try archive.addEntry(with: fileURL.lastPathComponent, relativeTo: workDir) }
            }

            try VaultGate.shared.withAccess(generation: epoch) {
                try fm.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: zipURL.path)
            }

            try? fm.removeItem(at: workDir)
            return try VaultGate.shared.withAccess(generation: epoch) { zipURL }
        } catch {
            try? fm.removeItem(at: workDir)
            try? fm.removeItem(at: exportDir)
            return nil
        }
    }
}
