import Foundation
import Compression

/// Small dependency-free reader for the OSM PBF primitives used by the
/// regional OSM databases. It intentionally keeps only tagged
/// nodes, ways and relations and converts them to the app's RestrictedPlace
/// geometry, so the downloaded PBF never becomes part of the live camera path.
enum OSMPBFPlaceParser {
    enum ParseError: LocalizedError {
        case invalidBlob, unsupportedCompression, invalidGeometry
        var errorDescription: String? {
            switch self {
            case .invalidBlob: return "Файл OSM обрезан или повреждён."
            case .unsupportedCompression: return "Не удалось распаковать блок OSM: неподдерживаемое сжатие или повреждённые данные."
            case .invalidGeometry: return "В базе OSM обнаружена неполная геометрия территории."
            }
        }
    }
    private static let maximumBlobSize = 32 * 1024 * 1024

    private struct Reader {
        let data: Data
        var index: Int = 0
        var isAtEnd: Bool { index >= data.count }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard index < data.count else { throw ParseError.invalidBlob }
                let byte = data[index]; index += 1
                guard shift < 63 || byte <= 1 else { throw ParseError.invalidBlob }
                value |= UInt64(byte & 0x7f) << UInt64(shift)
                if byte & 0x80 == 0 { return value }
            }
            throw ParseError.invalidBlob
        }

        mutating func bytes() throws -> Data {
            let rawLength = try varint()
            guard rawLength <= UInt64(OSMPBFPlaceParser.maximumBlobSize), rawLength <= UInt64(data.count - index) else { throw ParseError.invalidBlob }
            let length = Int(rawLength)
            let result = data.subdata(in: index..<(index + length)); index += length
            return result
        }

        mutating func field() throws -> (number: Int, wire: Int)? {
            guard !isAtEnd else { return nil }
            let key = try varint()
            guard key >> 3 > 0 else { throw ParseError.invalidBlob }
            return (Int(key >> 3), Int(key & 7))
        }

        mutating func skip(wire: Int) throws {
            switch wire {
            case 0: _ = try varint()
            case 1: guard index + 8 <= data.count else { throw ParseError.invalidBlob }; index += 8
            case 2: _ = try bytes()
            case 5: guard index + 4 <= data.count else { throw ParseError.invalidBlob }; index += 4
            default: throw ParseError.invalidBlob
            }
        }
    }

    private struct Member { let type: Int; let role: String; let ref: Int64 }
    private struct Way { let id: Int64; let tags: [String: String]; let refs: [Int64] }
    private struct Relation { let id: Int64; let tags: [String: String]; let members: [Member] }

    private static func signed(_ value: UInt64) -> Int64 {
        Int64(bitPattern: (value >> 1) ^ (~(value & 1) &+ 1))
    }

    private static func adding(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw ParseError.invalidBlob }
        return value
    }

    private static func coordinateValue(offset: Int64, granularity: Int64, value: Int64) throws -> Double {
        let (scaled, overflow) = granularity.multipliedReportingOverflow(by: value)
        guard granularity > 0, !overflow else { throw ParseError.invalidBlob }
        return 1e-9 * Double(try adding(offset, scaled))
    }

    private static func packedVarints(_ data: Data) throws -> [UInt64] {
        var reader = Reader(data: data); var values: [UInt64] = []
        while !reader.isAtEnd { values.append(try reader.varint()) }
        return values
    }

    private static func strings(_ data: Data) throws -> [String] {
        var reader = Reader(data: data); var result: [String] = []
        while let field = try reader.field() {
            guard field.number == 1, field.wire == 2 else { try reader.skip(wire: field.wire); continue }
            result.append(String(data: try reader.bytes(), encoding: .utf8) ?? "")
        }
        return result
    }

    private static func tags(keys: [UInt64], values: [UInt64], table: [String]) throws -> [String: String] {
        guard keys.count == values.count else { throw ParseError.invalidBlob }
        var result: [String: String] = [:]
        for index in keys.indices {
            guard keys[index] < UInt64(table.count), values[index] < UInt64(table.count) else { throw ParseError.invalidBlob }
            result[table[Int(keys[index])]] = table[Int(values[index])]
        }
        return result
    }

    private static func node(_ data: Data, table: [String], granularity: Int64, latOffset: Int64, lonOffset: Int64) throws -> (Int64, OSMCoordinate, [String: String]) {
        var reader = Reader(data: data), id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
        var keys: [UInt64] = [], values: [UInt64] = []
        while let field = try reader.field() {
            switch field.number {
            case 1: id = signed(try reader.varint())
            case 2: keys = try packedVarints(try reader.bytes())
            case 3: values = try packedVarints(try reader.bytes())
            case 8: lat = signed(try reader.varint())
            case 9: lon = signed(try reader.varint())
            default: try reader.skip(wire: field.wire)
            }
        }
        let coordinate = try OSMCoordinate(lat: coordinateValue(offset: latOffset, granularity: granularity, value: lat),
                                           lon: coordinateValue(offset: lonOffset, granularity: granularity, value: lon))
        guard coordinate.valid else { throw ParseError.invalidGeometry }
        return (id, coordinate, try tags(keys: keys, values: values, table: table))
    }

    private static func denseNodes(_ data: Data, table: [String], granularity: Int64, latOffset: Int64, lonOffset: Int64) throws -> [(Int64, OSMCoordinate, [String: String])] {
        var reader = Reader(data: data), ids: [UInt64] = [], lats: [UInt64] = [], lons: [UInt64] = [], keyValues: [UInt64] = []
        while let field = try reader.field() {
            switch field.number {
            case 1: ids = try packedVarints(try reader.bytes())
            case 5: _ = try reader.bytes() // DenseInfo, not node IDs.
            case 8: lats = try packedVarints(try reader.bytes())
            case 9: lons = try packedVarints(try reader.bytes())
            case 10: keyValues = try packedVarints(try reader.bytes())
            default: try reader.skip(wire: field.wire)
            }
        }
        var result: [(Int64, OSMCoordinate, [String: String])] = []
        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0, tagIndex = 0
        guard ids.count == lats.count, ids.count == lons.count else { throw ParseError.invalidBlob }
        for index in ids.indices {
            id = try adding(id, signed(ids[index])); lat = try adding(lat, signed(lats[index])); lon = try adding(lon, signed(lons[index]))
            var keyList: [UInt64] = [], valueList: [UInt64] = []
            while tagIndex < keyValues.count, keyValues[tagIndex] != 0 {
                keyList.append(keyValues[tagIndex]); tagIndex += 1
                guard tagIndex < keyValues.count else { break }
                valueList.append(keyValues[tagIndex]); tagIndex += 1
            }
            if !keyValues.isEmpty {
                guard tagIndex < keyValues.count, keyValues[tagIndex] == 0 else { throw ParseError.invalidBlob }
                tagIndex += 1
            }
            let coordinate = try OSMCoordinate(lat: coordinateValue(offset: latOffset, granularity: granularity, value: lat),
                                               lon: coordinateValue(offset: lonOffset, granularity: granularity, value: lon))
            guard coordinate.valid else { throw ParseError.invalidGeometry }
            result.append((id, coordinate, try tags(keys: keyList, values: valueList, table: table)))
        }
        guard tagIndex == keyValues.count else { throw ParseError.invalidBlob }
        return result
    }

    private static func way(_ data: Data, table: [String]) throws -> Way {
        var reader = Reader(data: data), id: Int64 = 0, keys: [UInt64] = [], values: [UInt64] = [], refs: [UInt64] = []
        while let field = try reader.field() {
            switch field.number {
            case 1: id = Int64(bitPattern: try reader.varint())
            case 2: keys = try packedVarints(try reader.bytes())
            case 3: values = try packedVarints(try reader.bytes())
            case 8: refs = try packedVarints(try reader.bytes())
            default: try reader.skip(wire: field.wire)
            }
        }
        var previous: Int64 = 0
        let decoded = try refs.map { value -> Int64 in previous = try adding(previous, signed(value)); return previous }
        return Way(id: id, tags: try tags(keys: keys, values: values, table: table), refs: decoded)
    }

    private static func relation(_ data: Data, table: [String]) throws -> Relation {
        var reader = Reader(data: data), id: Int64 = 0, keys: [UInt64] = [], values: [UInt64] = [], roles: [UInt64] = [], refs: [UInt64] = [], types: [UInt64] = []
        while let field = try reader.field() {
            switch field.number {
            case 1: id = Int64(bitPattern: try reader.varint())
            case 2: keys = try packedVarints(try reader.bytes())
            case 3: values = try packedVarints(try reader.bytes())
            case 8: roles = try packedVarints(try reader.bytes())
            case 9: refs = try packedVarints(try reader.bytes())
            case 10: types = try packedVarints(try reader.bytes())
            default: try reader.skip(wire: field.wire)
            }
        }
        var previous: Int64 = 0; var members: [Member] = []
        guard refs.count == roles.count, refs.count == types.count else { throw ParseError.invalidBlob }
        for index in 0..<min(refs.count, min(roles.count, types.count)) {
            previous = try adding(previous, signed(refs[index]))
            // roles_sid contains absolute string-table indexes (not deltas).
            let roleID = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: roles[index])))
            let role = roleID >= 0 && roleID < Int64(table.count) ? table[Int(roleID)] : ""
            guard types[index] <= 2 else { throw ParseError.invalidBlob }
            members.append(Member(type: Int(types[index]), role: role, ref: previous))
        }
        return Relation(id: id, tags: try tags(keys: keys, values: values, table: table), members: members)
    }

    private static func primitiveBlock(_ data: Data,
                                       nodes: inout [Int64: OSMCoordinate],
                                       taggedNodes: inout [(Int64, OSMCoordinate, [String: String])],
                                       ways: inout [Way], relations: inout [Relation],
                                       neededNodeIDs: Set<Int64>?) throws {
        var reader = Reader(data: data), table: [String] = [], groups: [Data] = [], granularity: Int64 = 100, latOffset: Int64 = 0, lonOffset: Int64 = 0
        while let field = try reader.field() {
            switch field.number {
            case 1: table = try strings(try reader.bytes())
            case 2: groups.append(try reader.bytes())
            case 17: granularity = Int64(bitPattern: try reader.varint())
            case 19: latOffset = Int64(bitPattern: try reader.varint())
            case 20: lonOffset = Int64(bitPattern: try reader.varint())
            default: try reader.skip(wire: field.wire)
            }
        }
        for groupData in groups {
            var group = Reader(data: groupData)
            while let field = try group.field() {
                switch field.number {
                case 1:
                    let item = try node(try group.bytes(), table: table, granularity: granularity, latOffset: latOffset, lonOffset: lonOffset)
                    if neededNodeIDs?.contains(item.0) == true { nodes[item.0] = item.1 }
                    if neededNodeIDs == nil, !item.2.isEmpty { taggedNodes.append(item) }
                case 2:
                    for item in try denseNodes(try group.bytes(), table: table, granularity: granularity, latOffset: latOffset, lonOffset: lonOffset) {
                        if neededNodeIDs?.contains(item.0) == true { nodes[item.0] = item.1 }
                        if neededNodeIDs == nil, !item.2.isEmpty { taggedNodes.append(item) }
                    }
                case 3:
                    let value = try way(try group.bytes(), table: table)
                    if neededNodeIDs == nil { ways.append(value) }
                case 4:
                    let value = try relation(try group.bytes(), table: table)
                    if neededNodeIDs == nil { relations.append(value) }
                default: try group.skip(wire: field.wire)
                }
            }
        }
    }

    private static func decode(_ compressed: Data, algorithm: compression_algorithm, expectedSize: Int) throws -> Data {
        guard !compressed.isEmpty else { throw ParseError.unsupportedCompression }
        guard expectedSize >= 0, expectedSize <= maximumBlobSize else { throw ParseError.invalidBlob }
        var capacity = min(max(expectedSize, compressed.count * 4, 4096), maximumBlobSize)
        // A regional PBF can contain blocks whose compression ratio is larger
        // than the advertised raw_size. Grow the output instead of treating
        // the first undersized decode as a corrupt database.
        for _ in 0..<8 {
            var output = Data(count: capacity)
            let sourceData: Data
            if algorithm == COMPRESSION_ZLIB, compressed.count > 6 {
                // OSM Blob.zlib_data is an RFC1950 stream. Apple's
                // COMPRESSION_ZLIB decoder expects the inner RFC1951 raw
                // DEFLATE payload, so remove the two-byte header and Adler32.
                sourceData = compressed.subdata(in: 2..<(compressed.count - 4))
            } else {
                sourceData = compressed
            }
            let decoded = output.withUnsafeMutableBytes { destination in
                sourceData.withUnsafeBytes { source in
                    guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(destinationBase, capacity, sourceBase,
                                                     sourceData.count, nil, algorithm)
                }
            }
            if decoded > 0 {
                output.removeSubrange(decoded..<output.count)
                return output
            }
            guard capacity < maximumBlobSize else { break }
            capacity = min(capacity * 2, maximumBlobSize)
        }
        throw ParseError.unsupportedCompression
    }

    private static func uncompressedBlob(_ data: Data) throws -> Data {
        var reader = Reader(data: data), raw: Data?, compressed: (Data, compression_algorithm)?, rawSize = 0
        while let field = try reader.field() {
            switch field.number {
            case 1: raw = try reader.bytes()
            case 2:
                let value = try reader.varint()
                guard value <= UInt64(maximumBlobSize) else { throw ParseError.invalidBlob }
                rawSize = Int(value)
            case 3: compressed = (try reader.bytes(), COMPRESSION_ZLIB)
            case 4: compressed = (try reader.bytes(), COMPRESSION_LZMA)
            case 6: compressed = (try reader.bytes(), COMPRESSION_LZ4)
            // zstd_data (field 7) is not exposed by Apple's Compression API
            // on the app's deployment SDK; those rare blocks are skipped as
            // unsupported rather than making the whole source uncompilable.
            default: try reader.skip(wire: field.wire)
            }
        }
        if let raw { return raw }
        guard let compressed else { throw ParseError.unsupportedCompression }
        return try decode(compressed.0, algorithm: compressed.1, expectedSize: rawSize)
    }

    private static func eachPrimitiveBlock(_ data: Data, _ body: (Data) throws -> Void, progress: ((Int, Int) -> Void)?) throws {
        var offset = 0, block = 0
        while offset + 4 <= data.count {
            let headerLength = Int(UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 | UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])); offset += 4
            guard headerLength > 0, offset + headerLength <= data.count else { throw ParseError.invalidBlob }
            var header = Reader(data: data.subdata(in: offset..<(offset + headerLength))); offset += headerLength
            var type = "", dataSize = 0
            while let field = try header.field() {
                switch field.number {
                case 1: type = String(data: try header.bytes(), encoding: .utf8) ?? ""
                case 3:
                    let value = try header.varint()
                    guard value <= UInt64(maximumBlobSize) else { throw ParseError.invalidBlob }
                    dataSize = Int(value)
                default: try header.skip(wire: field.wire)
                }
            }
            guard dataSize > 0, dataSize <= maximumBlobSize, offset + dataSize <= data.count else { throw ParseError.invalidBlob }
            let blob = try uncompressedBlob(data.subdata(in: offset..<(offset + dataSize))); offset += dataSize
            if type == "OSMData" { try body(blob); block += 1; progress?(offset, data.count) }
        }
        guard offset == data.count, block > 0 else { throw ParseError.invalidBlob }
    }

    static func parse(url: URL, progress: ((Int, Int) -> Void)? = nil) throws -> [RestrictedPlace] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        // The first pass keeps only tagged nodes plus way/relation references.
        // Keeping every node from a regional PBF was the dominant memory cost.
        var firstPassNodes: [Int64: OSMCoordinate] = [:]
        var taggedNodes: [(Int64, OSMCoordinate, [String: String])] = []
        var ways: [Way] = [], relations: [Relation] = []
        try eachPrimitiveBlock(data, { block in
            try primitiveBlock(block, nodes: &firstPassNodes, taggedNodes: &taggedNodes,
                              ways: &ways, relations: &relations, neededNodeIDs: nil)
        }, progress: { done, total in
            progress?(done, total * 2)
        })

        var relationByID: [Int64: Relation] = [:]
        for relation in relations {
            guard relationByID.updateValue(relation, forKey: relation.id) == nil else { throw ParseError.invalidBlob }
        }
        let restrictedRelations = relations.filter { RestrictedPlaceKind.classify($0.tags) != nil }.map { relation in
            Relation(id: relation.id, tags: relation.tags,
                     members: flattenedMembers(relation, relations: relationByID, visited: []))
        }
        var neededWayIDs = Set(ways.compactMap { RestrictedPlaceKind.classify($0.tags) == nil ? nil : $0.id })
        for relation in restrictedRelations {
            neededWayIDs.formUnion(relation.members.filter { $0.type == 1 }.map(\.ref))
        }
        let retainedWays = ways.filter { neededWayIDs.contains($0.id) }
        var neededNodeIDs = Set(retainedWays.flatMap(\.refs))
        neededNodeIDs.formUnion(restrictedRelations.flatMap { $0.members.filter { $0.type == 0 }.map(\.ref) })

        // The second pass decodes coordinates only for nodes referenced by a
        // restricted way or relation. A mapped file remains cheap to reread,
        // while the live dictionaries stay bounded by relevant geometry.
        var nodes: [Int64: OSMCoordinate] = [:]
        var ignoredTaggedNodes: [(Int64, OSMCoordinate, [String: String])] = []
        try eachPrimitiveBlock(data, { block in
            try primitiveBlock(block, nodes: &nodes, taggedNodes: &ignoredTaggedNodes,
                              ways: &ways, relations: &relations,
                              neededNodeIDs: neededNodeIDs)
        }, progress: { done, total in
            progress?(total + done, total * 2)
        })
        var places: [RestrictedPlace] = taggedNodes.compactMap { item in
            guard let kind = RestrictedPlaceKind.classify(item.2) else { return nil }
            return RestrictedPlace(id: "node/\(item.0)", kind: kind, name: item.2["name:ru"] ?? item.2["name"], point: item.1, lines: [], outerRings: [], innerRings: [])
        }
        for way in retainedWays { if let place = makePlace(way, nodes: nodes) { places.append(place) } }
        var wayByID: [Int64: Way] = [:]
        for way in retainedWays {
            guard wayByID.updateValue(way, forKey: way.id) == nil else { throw ParseError.invalidBlob }
        }
        for relation in restrictedRelations { if let place = makePlace(relation, ways: wayByID, nodes: nodes) { places.append(place) } }
        return places
    }

    private static func makePlace(_ way: Way, nodes: [Int64: OSMCoordinate]) -> RestrictedPlace? {
        guard let kind = RestrictedPlaceKind.classify(way.tags) else { return nil }
        let runs = coordinateRuns(way.refs, nodes: nodes)
        guard !runs.isEmpty else { return nil }
        if let geometry = runs.first, runs.count == 1, geometry.count == way.refs.count,
           geometry.count >= 4, way.refs.first == way.refs.last, way.tags["area"] != "no" {
            return RestrictedPlace(id: "way/\(way.id)", kind: kind, name: way.tags["name:ru"] ?? way.tags["name"], point: nil, lines: [], outerRings: [geometry], innerRings: [])
        }
        return RestrictedPlace(id: "way/\(way.id)", kind: kind, name: way.tags["name:ru"] ?? way.tags["name"], point: nil, lines: runs, outerRings: [], innerRings: [])
    }

    /// Never connect the two sides of an absent node with an invented edge.
    private static func coordinateRuns(_ refs: [Int64], nodes: [Int64: OSMCoordinate]) -> [[OSMCoordinate]] {
        var result: [[OSMCoordinate]] = [], current: [OSMCoordinate] = []
        for ref in refs {
            if let coordinate = nodes[ref] { current.append(coordinate) }
            else if !current.isEmpty { result.append(current); current = [] }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func flattenedMembers(_ relation: Relation, relations: [Int64: Relation], visited: Set<Int64>) -> [Member] {
        guard !visited.contains(relation.id), visited.count < 64 else { return [] }
        var visited = visited; visited.insert(relation.id)
        return relation.members.flatMap { member -> [Member] in
            guard member.type == 2 else { return [member] }
            guard let child = relations[member.ref] else { return [] }
            return flattenedMembers(child, relations: relations, visited: visited).map { nested in
                let role: String
                if member.role == "inner" { role = nested.role == "inner" ? "outer" : "inner" }
                else { role = nested.role }
                return Member(type: nested.type, role: role, ref: nested.ref)
            }
        }
    }

    private static func makePlace(_ relation: Relation, ways: [Int64: Way], nodes: [Int64: OSMCoordinate]) -> RestrictedPlace? {
        guard let kind = RestrictedPlaceKind.classify(relation.tags) else { return nil }
        var outerRefs: [[Int64]] = [], innerRefs: [[Int64]] = [], lines: [[OSMCoordinate]] = []
        if relation.tags["type"] == "site" {
            var footprints: [[OSMCoordinate]] = []
            for member in relation.members {
                if member.type == 0, let coordinate = nodes[member.ref] { lines.append([coordinate]) }
                else if member.type == 1, let way = ways[member.ref] {
                    let runs = coordinateRuns(way.refs, nodes: nodes)
                    if let geometry = runs.first, runs.count == 1, geometry.count == way.refs.count,
                       geometry.count >= 4, way.refs.first == way.refs.last, way.tags["area"] != "no" {
                        footprints.append(geometry)
                    } else { lines.append(contentsOf: runs) }
                }
            }
            guard !lines.isEmpty || !footprints.isEmpty else { return nil }
            return RestrictedPlace(id: "relation/\(relation.id)", kind: kind, name: relation.tags["name:ru"] ?? relation.tags["name"], point: nil, lines: lines, outerRings: footprints, innerRings: [])
        }
        for member in relation.members where member.type == 1 {
            guard let way = ways[member.ref] else { continue }
            guard way.refs.count >= 2 else { continue }
            // Multipolygon boundaries are often split into open way fragments.
            // Join both closed and open fragments before converting to geometry.
            if member.role == "inner" { innerRefs.append(way.refs) }
            else if member.role == "outer" || member.role.isEmpty || way.refs.first == way.refs.last { outerRefs.append(way.refs) }
            else { lines.append(contentsOf: coordinateRuns(way.refs, nodes: nodes)) }
        }
        func geometries(_ fragments: [[Int64]]) -> [[OSMCoordinate]] {
            joinRings(fragments).compactMap { refs in
                let runs = coordinateRuns(refs, nodes: nodes)
                guard let geometry = runs.first, runs.count == 1, geometry.count == refs.count,
                      refs.count >= 4, refs.first == refs.last else {
                    lines.append(contentsOf: runs)
                    return nil
                }
                return geometry
            }
        }
        let outer = geometries(outerRefs)
        let inner = geometries(innerRefs)
        guard !outer.isEmpty || !inner.isEmpty || !lines.isEmpty else { return nil }
        return RestrictedPlace(id: "relation/\(relation.id)", kind: kind, name: relation.tags["name:ru"] ?? relation.tags["name"], point: nil, lines: lines, outerRings: outer, innerRings: inner)
    }

    private static func joinRings(_ fragments: [[Int64]]) -> [[Int64]] {
        var pending = fragments, result: [[Int64]] = []
        while !pending.isEmpty {
            var ring = pending.removeFirst()
            var changed = true
            while changed && ring.first != ring.last {
                changed = false
                for index in pending.indices.reversed() {
                    var next = pending[index]
                    if next.first == ring.last { ring.append(contentsOf: next.dropFirst()) }
                    else if next.last == ring.last { next.reverse(); ring.append(contentsOf: next.dropFirst()) }
                    else if next.last == ring.first { ring.insert(contentsOf: next.dropLast(), at: 0) }
                    else if next.first == ring.first { next.reverse(); ring.insert(contentsOf: next.dropLast(), at: 0) }
                    else { continue }
                    pending.remove(at: index); changed = true; break
                }
            }
            result.append(ring)
        }
        return result
    }
}

