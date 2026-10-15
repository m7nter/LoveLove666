import Foundation
import CoreLocation

struct ArchiveMetadataOptions: OptionSet, Equatable {
    let rawValue: Int
    static let coordinates = Self(rawValue: 1 << 0)
    static let date = Self(rawValue: 1 << 1)
    static let folder = Self(rawValue: 1 << 2)
    static let event = Self(rawValue: 1 << 3)
    static let numbering = Self(rawValue: 1 << 4)
    static let notes = Self(rawValue: 1 << 5)
    static let mapLink = Self(rawValue: 1 << 6)
    static let all: Self = [.coordinates, .date, .folder, .event, .numbering, .notes, .mapLink]
    static let standard: Self = [.coordinates, .date, .folder, .event, .numbering, .mapLink]
    static let fields: [(String, Self)] = [
        ("Координаты", .coordinates), ("Дата и время съёмки", .date), ("Папка", .folder),
        ("Событие и номер кадра", .event), ("Нумерация фото", .numbering),
        ("Заметки", .notes), ("Ссылка на карту", .mapLink)
    ]
}

struct ExportPhotoRecord {
    let filename: String
    let meta: PhotoMeta?
    let folder: String
}

enum ExportMetadata {
    static func coordinates(_ meta: PhotoMeta?) -> String? {
        guard let meta, meta.hasLocation != false,
              meta.hasLocation == true || meta.latitude != 0 || meta.longitude != 0,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: meta.latitude, longitude: meta.longitude)) else { return nil }
        return String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), meta.latitude, meta.longitude)
    }

    // The numbering follows attachment order, including photos without GPS.
    static func coordinateMessage(_ records: [ExportPhotoRecord], exportedAt: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd.MM.yyyy"
        return "Выгрузка \(formatter.string(from: exportedAt)). Координаты:\n"
            + records.enumerated().map { "\($0.offset + 1)) \(coordinates($0.element.meta) ?? "нет данных")" }.joined(separator: "\n")
    }

    static func archiveText(_ records: [ExportPhotoRecord], options: ArchiveMetadataOptions) -> String? {
        guard !options.isEmpty else { return nil }
        // This preset contains literally just numbered coordinates, without
        // filenames, dates, folder names, event IDs, notes or map links.
        if options == .coordinates {
            return records.enumerated().map { "\($0.offset + 1)) \(coordinates($0.element.meta) ?? "нет данных")" }.joined(separator: "\n") + "\n"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        return records.map { record in
            var lines = ["Файл: \(record.filename)"]
            if options.contains(.coordinates) { lines.append("Координаты: \(coordinates(record.meta) ?? "нет данных")") }
            if options.contains(.mapLink), let location = coordinates(record.meta) {
                lines.append("Карта: https://maps.google.com/?q=" + location.replacingOccurrences(of: " ", with: ""))
            }
            if options.contains(.date), let meta = record.meta { lines.append("Дата съёмки: " + formatter.string(from: meta.date)) }
            if options.contains(.folder) { lines.append("Папка: " + record.folder) }
            if options.contains(.event), let meta = record.meta {
                lines.append("Событие: \(meta.eventNumber.map(String.init) ?? "отдельный снимок")")
                lines.append("Кадр: \(meta.eventIndex ?? 1) / \(meta.eventCount ?? 1)")
            }
            if options.contains(.numbering), let meta = record.meta {
                if let value = meta.dailyNumber { lines.append("За день: \(value)") }
                if let value = meta.totalNumber { lines.append("Общий номер: \(value)") }
            }
            if options.contains(.notes), let note = record.meta?.note, !note.isEmpty { lines.append("Заметка: " + note) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    static func messageParts(_ message: String, maximumLength: Int = 3800) -> [String] {
        var result: [String] = []
        var current = ""
        for line in message.components(separatedBy: "\n") {
            if !current.isEmpty && current.count + line.count + 1 > maximumLength {
                result.append(current); current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
