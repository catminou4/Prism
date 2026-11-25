import Foundation

/// Versioned container of independently compressed segments, so that large caches are encoded
/// and decoded in parallel. Version 1 payloads are LZFSE-compressed JSON (one decoder per
/// segment); version 2 payloads are the `BinaryArchive` encoding — the container is unchanged.
///
/// Layout: `"PRSG"` magic · format version (UInt32 LE) · segment count (UInt32 LE) ·
/// per segment: tag (UInt8) + byte length (UInt32 LE) · then the compressed payloads.
/// Any mismatch (magic, version, truncated data) makes unpacking return `nil`.
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

    /// Unpacks any well-formed archive, reporting the version read from its header. Callers
    /// pick the codec from that version: caches decode every format they still understand
    /// instead of only their own, which is what makes in-place migration possible.
    static func unpack(_ data: Data) -> (version: UInt32, segments: [Segment])? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count == 12, Array(bytes[0..<4]) == magic else { return nil }
        let version = readUInt32(bytes, at: 4)
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
            segments.append(Segment(tag: tag, payload: data[offset ..< offset + length]))
            offset += length
        }
        return (version, segments)
    }

    static func unpack(_ data: Data, version: UInt32) -> [Segment]? {
        guard let unpacked = unpack(data), unpacked.version == version else { return nil }
        return unpacked.segments
    }

    /// Deletes `*.<suffix>` archives in `directory` whose embedded version is not in `versions`
    /// — the versions this build can still decode, including migratable legacy ones — or that
    /// are truncated/foreign (they can never be decoded). Reads only the 8-byte header of each
    /// file; cheap enough to run once at launch, off the main actor.
    static func purgeObsoleteFiles(in directory: URL, versions: Set<UInt32>, suffix: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for name in names where name.hasSuffix("." + suffix) {
            let url = directory.appending(path: name)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory != true else { continue }
            // A bounded read of just the header bytes: `Data(contentsOf: .mappedIfSafe)` maps
            // the whole archive (hundreds of megabytes of address space / page-table work per
            // file) to inspect 8 bytes.
            let header = readHeader(url, count: 8)
            let readable = header.count == 8 && Array(header.prefix(4)) == magic
                && versions.contains(readUInt32([UInt8](header.dropFirst(4)), at: 0))
            if !readable { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// The first `count` bytes of a file, without mapping it.
    private static func readHeader(_ url: URL, count: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    // MARK: Segments

    static func encodeSegment<T: Encodable>(_ value: T, tag: UInt8) throws -> Segment {
        try autoreleasepool {
            let json = try JSONEncoder().encode(value)
            return Segment(tag: tag, payload: try (json as NSData).compressed(using: .lzfse) as Data)
        }
    }

    static func decodeSegment<T: Decodable>(_ type: T.Type, from segment: Segment) -> T? {
        autoreleasepool {
            guard let json = try? (segment.payload as NSData).decompressed(using: .lzfse) as Data else { return nil }
            return try? JSONDecoder().decode(T.self, from: json)
        }
    }

    /// Expands chunks a few at a time, then appends them in archive order. Chunk decoding is
    /// CPU-bound and single-threaded per chunk, so the window tracks the core count (capped):
    /// 77 catalog segments at 4-wide left most cores idle during the decode.
    ///
    /// The pipeline is a rolling window inside a single task group: as soon as one chunk
    /// finishes, its slot is refilled *before* the finished chunks are appended in archive
    /// order — so the serial append/copy work (retain traffic on every reference in every
    /// item) overlaps the parallel decoding instead of serializing wave after wave.
    static func decodeChunks<Chunk: Sendable, Result>(
        _ segments: ArraySlice<Segment>, into initial: Result,
        decode: @escaping @Sendable (Segment) -> Chunk?, append: (inout Result, Chunk) -> Void
    ) async -> Result? {
        var result = initial
        let window = min(max(4, ProcessInfo.processInfo.activeProcessorCount), 10)
        return await withTaskGroup(of: (Int, Chunk?).self) { group in
            var nextSubmission = segments.startIndex
            var inFlight = 0
            func submit() {
                let segment = segments[nextSubmission]
                let index = nextSubmission
                group.addTask { (index, Task.isCancelled ? nil : decode(segment)) }
                inFlight += 1
                nextSubmission += 1
            }
            while inFlight < window, nextSubmission < segments.endIndex { submit() }
            // Chunks completed out of order, waiting for their predecessors to be appended.
            // A nil chunk (corrupt segment) poisons the archive wherever it lands, so it is
            // handled on arrival instead of entering the reorder buffer — which also keeps
            // the buffer free of the dictionary nil-assignment trap.
            var pending: [Int: Chunk] = [:]
            var nextAppend = segments.startIndex
            var failed = false
            while let (index, chunk) = await group.next() {
                inFlight -= 1
                if Task.isCancelled { group.cancelAll() }
                if chunk == nil { failed = true }
                // Refill first: the append below is serial work on this task, and the
                // window must stay saturated while it runs. Once the archive is poisoned
                // the window only drains.
                if !failed, !Task.isCancelled {
                    while inFlight < window, nextSubmission < segments.endIndex { submit() }
                } else {
                    group.cancelAll()
                }
                if let chunk { pending[index] = chunk }
                while let ready = pending.removeValue(forKey: nextAppend) {
                    guard !failed else { break }
                    append(&result, ready)
                    nextAppend += 1
                }
            }
            // A corrupt chunk (nil) or cancellation poison the whole archive: partial
            // catalogs must never reach the caller.
            guard !failed, !Task.isCancelled, nextAppend == segments.endIndex else { return nil }
            return result
        }
    }

    private struct Chunk<Item: Encodable>: Encodable {
        let items: ArraySlice<Item>

        func encode(to encoder: any Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(contentsOf: items)
        }
    }

    /// Encodes `items` in chunks of `chunkSize`, at most six chunks in flight (each holds a full
    /// document plus its compressed form, so an unbounded group multiplied peak memory by
    /// the chunk count), preserving archive order.
    static func encodeChunks<T: Encodable & Sendable>(_ items: [T], tag: UInt8, chunkSize: Int) async throws -> [Segment] {
        try await encodeChunks(items, chunkSize: chunkSize) { slice in
            try encodeSegment(Chunk(items: slice), tag: tag)
        }
    }

    /// Chunked parallel encode with the segment encoding left to the caller — version 1 passes
    /// the JSON encoder above, version 2 the binary codec. Same batching, same order.
    static func encodeChunks<T: Sendable>(
        _ items: [T], chunkSize: Int,
        encode: @escaping @Sendable (ArraySlice<T>) throws -> Segment
    ) async throws -> [Segment] {
        let batchSize = 6
        // The batch span multiplies chunkSize by batchSize: keep it far from Int.max.
        precondition(chunkSize > 0 && chunkSize <= Int.max / batchSize)
        guard !items.isEmpty else { return [] }
        var segments: [Segment] = []
        var lower = 0
        while lower < items.count {
            try Task.checkCancellation()
            let upper = min(lower + chunkSize * batchSize, items.count)
            let batch = try await withThrowingTaskGroup(of: (Int, Segment).self) { group in
                for start in stride(from: lower, to: upper, by: chunkSize) {
                    let end = min(start + chunkSize, items.count)
                    group.addTask {
                        try Task.checkCancellation()
                        return (start, try encode(items[start..<end]))
                    }
                }
                var parts: [(Int, Segment)] = []
                for try await part in group { parts.append(part) }
                return parts.sorted { $0.0 < $1.0 }.map(\.1)
            }
            segments.append(contentsOf: batch)
            lower = upper
        }
        return segments
    }

    // MARK: Integers

    static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
}
