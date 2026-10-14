import Foundation

struct PhotoEventGroup: Identifiable {
    let id: String
    let title: String
    let urls: [URL]
    let date: Date
}

struct GalleryRecord {
    let url: URL
    let meta: PhotoMeta?
    let date: Date
    let folder: String
    let eventKey: String
}

struct GalleryDayGroup: Identifiable {
    let id: String
    let date: Date
    let events: [PhotoEventGroup]
    var urls: [URL] { events.flatMap(\.urls) }
}

enum GalleryGrouping {
    static func events(_ records: [GalleryRecord]) -> [PhotoEventGroup] {
        Dictionary(grouping: records, by: \.eventKey).map { key, members in
            let ordered = members.sorted {
                let lhs = $0.meta?.eventIndex ?? 1, rhs = $1.meta?.eventIndex ?? 1
                if lhs != rhs { return lhs < rhs }
                return $0.date == $1.date ? $0.url.path < $1.url.path : $0.date < $1.date
            }
            let first = ordered[0]
            return PhotoEventGroup(id: key,
                title: first.meta?.eventNumber.map { "Событие \($0)" } ?? "Отдельный снимок",
                urls: ordered.map(\.url), date: first.date)
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
    static func days(_ events: [PhotoEventGroup]) -> [GalleryDayGroup] {
        Dictionary(grouping: events, by: { FileStorageManager.dayKey($0.date) }).map { key, members in
            GalleryDayGroup(id: key, date: members[0].date, events: members.sorted { $0.date > $1.date })
        }.sorted { $0.id > $1.id }
    }
}
