import Foundation
import Compression

/// Small dependency-free reader for the OSM PBF primitives used by the
/// regional Awesome Coord databases. It intentionally keeps only tagged
/// nodes, ways and relations and converts them to the app's RestrictedPlace
/// geometry, so the downloaded PBF never becomes part of the live camera path.
enum OSMPBFPlaceParser {
    enum ParseError: Error { case invalidBlob, unsupportedCompression, invalidGeometry }

    private struct Reader {
        let data: Data
        var index: Int = 0
        var isAtEnd: Bool { index >= data.count }

        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, to: 64, by: 7) {
                guard index < data.count else { throw ParseError.invalidBlob }
                let byte = data[index]; index += 1
                value |= UInt64(byte & 0x7f) << UInt64(shift)
                if byte & 0x80 == 0 { return value }
            }
            throw ParseError.invalidBlob
        }

        mutating func bytes() throws -> Data {
            let length = Int(try varint())
            guard length >= 0, index + length <= data.count else { throw ParseError.invalidBlob }
            let result = data.subdata(in: index..<(index + length)); index += length
            return result
        }

        mutating func field() throws -> (number: Int, wire: Int)? {
            guard !isAtEnd else { return nil }
            let key = try varint()
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
        Int64((value >> 1) ^ (~(value & 1) &+ 1))
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

    private static func tags(keys: [UInt64], values: [UInt64], table: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for index in 0..<min(keys.count, values.count) {
            let key = Int(keys[index]), value = Int(values[index])
            if key >= 0, key < table.count, value >= 0, value < table.count { result[table[key]] = table[value] }
        }
        return result
    }

    private static func node(_ data: Data, table: [String], granularity: Int64, latOffset: Int64, lonOffset: Int64) throws -> (Int64, OSMCoordinate, [String: String]) {
        var reader = Reader(data: data), id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
        var keys: [UInt64] = [], values: [UInt64] = []
        while let field = try reader.field() {
            switch field.number {
            case 1: id = Int64(bitPattern: try reader.varint())
            case 2: keys = try packedVarints(try reader.bytes())
            case 3: values = try packedVarints(try reader.bytes())
            case 8: lat = Int64(bitPattern: try reader.varint())
            case 9: lon = Int64(bitPattern: try reader.varint())
            default: try reader.skip(wire: field.wire)
            }
        }
        let coordinate = OSMCoordinate(lat: 1e-9 * Double(latOffset + granularity * lat), lon: 1e-9 * Double(lonOffset + granularity * lon))
        guard coordinate.valid else { throw ParseError.invalidGeometry }
        return (id, coordinate, tags(keys: keys, values: values, table: table))
    }

    private static func denseNodes(_ data: Data, table: [String], granularity: Int64, latOffset: Int64, lonOffset: Int64) throws -> [(Int64, OSMCoordinate, [String: String])] {
        var reader = Reader(data: data), ids: [UInt64] = [], lats: [UInt64] = [], lons: [UInt64] = [], keyValues: [UInt64] = []
        while let field = try reader.field() {
            switch field.number {
            case 1: _ = try reader.bytes() // DenseInfo is not needed.
            case 5: ids = try packedVarints(try reader.bytes())
            case 8: lats = try packedVarints(try reader.bytes())
            case 9: lons = try packedVarints(try reader.bytes())
            case 10: keyValues = try packedVarints(try reader.bytes())
            default: try reader.skip(wire: field.wire)
            }
        }
        var result: [(Int64, OSMCoordinate, [String: String])] = []
        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0, tagIndex = 0
        for index in 0..<min(ids.count, min(lats.count, lons.count)) {
            id += signed(ids[index]); lat += signed(lats[index]); lon += signed(lons[index])
            var keyList: [UInt64] = [], valueList: [UInt64] = []
            while tagIndex < keyValues.count, keyValues[tagIndex] != 0 {
                keyList.append(keyValues[tagIndex]); tagIndex += 1
                guard tagIndex < keyValues.count else { break }
                valueList.append(keyValues[tagIndex]); tagIndex += 1
            }
            if tagIndex < keyValues.count { tagIndex += 1 }
            let coordinate = OSMCoordinate(lat: 1e-9 * Double(latOffset + granularity * lat), lon: 1e-9 * Double(lonOffset + granularity * lon))
            if coordinate.valid { result.append((id, coordinate, tags(keys: keyList, values: valueList, table: table))) }
        }
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
        let decoded = refs.map { value -> Int64 in previous += signed(value); return previous }
        return Way(id: id, tags: tags(keys: keys, values: values, table: table), refs: decoded)
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
        var previous: Int64 = 0, roleID: Int64 = 0; var members: [Member] = []
        for index in 0..<min(refs.count, min(roles.count, types.count)) {
            previous += signed(refs[index])
            // roles_sid is a delta-coded int32 array in the OSM PBF schema.
            roleID += Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: roles[index])))
            let role = roleID >= 0 && roleID < Int64(table.count) ? table[Int(roleID)] : ""
            members.append(Member(type: Int(types[index]), role: role, ref: previous))
        }
        return Relation(id: id, tags: tags(keys: keys, values: values, table: table), members: members)
    }

    private static func primitiveBlock(_ data: Data, nodes: inout [Int64: OSMCoordinate], taggedNodes: inout [(Int64, OSMCoordinate, [String: String])], ways: inout [Way], relations: inout [Relation]) throws {
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
                    let item = try node(try group.bytes(), table: table, granularity: granularity, latOffset: latOffset, lonOffset: lonOffset); nodes[item.0] = item.1; if !item.2.isEmpty { taggedNodes.append(item) }
                case 2:
                    for item in try denseNodes(try group.bytes(), table: table, granularity: granularity, latOffset: latOffset, lonOffset: lonOffset) { nodes[item.0] = item.1; if !item.2.isEmpty { taggedNodes.append(item) } }
                case 3: ways.append(try way(try group.bytes(), table: table))
                case 4: relations.append(try relation(try group.bytes(), table: table))
                default: try group.skip(wire: field.wire)
                }
            }
        }
    }

    private static func decode(_ compressed: Data, algorithm: compression_algorithm, expectedSize: Int) throws -> Data {
        guard !compressed.isEmpty else { throw ParseError.unsupportedCompression }
        var capacity = max(expectedSize, compressed.count * 4, 4096)
        // A regional PBF can contain blocks whose compression ratio is larger
        // than the advertised raw_size. Grow the output instead of treating
        // the first undersized decode as a corrupt database.
        for _ in 0..<8 {
            var output = Data(count: capacity)
            let decoded = output.withUnsafeMutableBytes { destination in
                compressed.withUnsafeBytes { source in
                    guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                          let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(destinationBase, capacity, sourceBase,
                                                     compressed.count, nil, algorithm)
                }
            }
            if decoded > 0 {
                output.removeSubrange(decoded..<output.count)
                return output
            }
            capacity *= 2
        }
        throw ParseError.unsupportedCompression
    }

    private static func uncompressedBlob(_ data: Data) throws -> Data {
        var reader = Reader(data: data), raw: Data?, compressed: (Data, compression_algorithm)?, rawSize = 0
        while let field = try reader.field() {
            switch field.number {
            case 1: raw = try reader.bytes()
            case 2: rawSize = Int(try reader.varint())
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
                switch field.number { case 1: type = String(data: try header.bytes(), encoding: .utf8) ?? ""; case 3: dataSize = Int(try header.varint()); default: try header.skip(wire: field.wire) }
            }
            guard dataSize > 0, offset + dataSize <= data.count else { throw ParseError.invalidBlob }
            let blob = try uncompressedBlob(data.subdata(in: offset..<(offset + dataSize))); offset += dataSize
            if type == "OSMData" { try body(blob); block += 1; progress?(offset, data.count) }
        }
    }

    static func parse(url: URL, progress: ((Int, Int) -> Void)? = nil) throws -> [RestrictedPlace] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var nodes: [Int64: OSMCoordinate] = [:], taggedNodes: [(Int64, OSMCoordinate, [String: String])] = [], ways: [Way] = [], relations: [Relation] = []
        try eachPrimitiveBlock(data, { try primitiveBlock($0, nodes: &nodes, taggedNodes: &taggedNodes, ways: &ways, relations: &relations) }, progress: progress)
        var places: [RestrictedPlace] = taggedNodes.compactMap { item in
            guard let kind = RestrictedPlaceKind.classify(item.2) else { return nil }
            return RestrictedPlace(id: "node/\(item.0)", kind: kind, name: item.2["name:ru"] ?? item.2["name"], point: item.1, lines: [], outerRings: [], innerRings: [])
        }
        for way in ways { if let place = makePlace(way, nodes: nodes) { places.append(place) } }
        let wayByID = Dictionary(uniqueKeysWithValues: ways.map { ($0.id, $0) })
        for relation in relations { if let place = makePlace(relation, ways: wayByID, nodes: nodes) { places.append(place) } }
        return places
    }

    private static func makePlace(_ way: Way, nodes: [Int64: OSMCoordinate]) -> RestrictedPlace? {
        guard let kind = RestrictedPlaceKind.classify(way.tags) else { return nil }
        let geometry = way.refs.compactMap { nodes[$0] }; guard geometry.count >= 2 else { return nil }
        if geometry.first == geometry.last, way.tags["area"] != "no" { return RestrictedPlace(id: "way/\(way.id)", kind: kind, name: way.tags["name:ru"] ?? way.tags["name"], point: nil, lines: [], outerRings: [geometry], innerRings: []) }
        return RestrictedPlace(id: "way/\(way.id)", kind: kind, name: way.tags["name:ru"] ?? way.tags["name"], point: nil, lines: [geometry], outerRings: [], innerRings: [])
    }

    private static func makePlace(_ relation: Relation, ways: [Int64: Way], nodes: [Int64: OSMCoordinate]) -> RestrictedPlace? {
        guard let kind = RestrictedPlaceKind.classify(relation.tags) else { return nil }
        var outerRefs: [[Int64]] = [], innerRefs: [[Int64]] = [], lines: [[OSMCoordinate]] = []
        for member in relation.members where member.type == 1 {
            guard let way = ways[member.ref] else { continue }
            guard way.refs.count >= 2 else { continue }
            // Multipolygon boundaries are often split into open way fragments.
            // Join both closed and open fragments before converting to geometry.
            if member.role == "inner" { innerRefs.append(way.refs) }
            else if member.role == "outer" || way.refs.first == way.refs.last { outerRefs.append(way.refs) }
            else { lines.append(way.refs.compactMap { nodes[$0] }) }
        }
        let outer = joinRings(outerRefs).map { $0.compactMap { nodes[$0] } }.filter { $0.count >= 4 }
        let inner = joinRings(innerRefs).map { $0.compactMap { nodes[$0] } }.filter { $0.count >= 4 }
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

