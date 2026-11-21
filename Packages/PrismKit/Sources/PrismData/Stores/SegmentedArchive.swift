import Foundation

/// Versioned container of independently compressed JSON segments, so that large caches are encoded
/// and decoded in parallel (one JSONDecoder per segment, all cores busy).
///
/// Layout: `"PRSG"` magic · format version (UInt32 LE) · segment count (UInt32 LE) ·
/// per segment: tag (UInt8) + byte length (UInt32 LE) · then the LZFSE-compressed JSON payloads.
/// Any mismatch (magic, version, truncated data) makes `segments(in:version:)` return `nil`.
enum SegmentedArchive {
    struct Segment: Sendable {
        var tag: UInt8
        /// LZFSE-compressed JSON.
        var payload: Data
    }

    static let magic: [UInt8] = Array("PRSG".utf8)

    // MARK: Container

    static func pack(_ segments: [Segment], version: UInt32) -> Data {
        var data = Data(capacity: 12 + segments.count * 5 + segments.reduce(0) { $0 + $1.payload.count })
        data.append(contentsOf: magic)
        appendUInt32(version, to: &data)
        appendUInt32(UInt32(segments.count), to: &data)
        for segment in segments {
            data.append(segment.tag)
            appendUInt32(UInt32(segment.payload.count), to: &data)
        }
        for segment in segments { data.append(segment.payload) }
        return data
    }

    static func unpack(_ data: Data, version: UInt32) -> [Segment]? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count == 12, Array(bytes[0..<4]) == magic, readUInt32(bytes, at: 4) == version else { return nil }
        let count = Int(readUInt32(bytes, at: 8))
        let tableSize = count * 5
        guard count >= 0, count < 100_000, data.count >= 12 + tableSize else { return nil }
        let table = [UInt8](data[data.startIndex + 12 ..< data.startIndex + 12 + tableSize])
        var offset = data.startIndex + 12 + tableSize
        var segments: [Segment] = []
        segments.reserveCapacity(count)
        for index in 0..<count {
            let tag = table[index * 5]
            let length = Int(readUInt32(table, at: index * 5 + 1))
            guard offset + length <= data.endIndex else { return nil }
            segments.append(Segment(tag: tag, payload: data.subdata(in: offset ..< offset + length)))
            offset += length
        }
        return segments
    }

    // MARK: Segments

    static func encodeSegment<T: Encodable>(_ value: T, tag: UInt8) throws -> Segment {
        let json = try JSONEncoder().encode(value)
        return Segment(tag: tag, payload: try (json as NSData).compressed(using: .lzfse) as Data)
    }

    static func decodeSegment<T: Decodable>(_ type: T.Type, from segment: Segment) -> T? {
        guard let json = try? (segment.payload as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: json)
    }

    /// Encodes `items` in chunks of `chunkSize`, concurrently, preserving order.
    static func encodeChunks<T: Encodable & Sendable>(_ items: [T], tag: UInt8, chunkSize: Int) async throws -> [Segment] {
        guard !items.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, Segment).self) { group in
            for (index, lower) in stride(from: 0, to: items.count, by: chunkSize).enumerated() {
                let upper = min(lower + chunkSize, items.count)
                group.addTask { (index, try encodeSegment(Array(items[lower..<upper]), tag: tag)) }
            }
            var parts: [(Int, Segment)] = []
            for try await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // MARK: Integers

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
