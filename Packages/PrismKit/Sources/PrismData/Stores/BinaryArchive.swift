import Foundation
import PrismCore

/// Binary encoding of the per-segment payloads (archive format version 2).
///
/// JSON parsing was 85 % of the launch-critical cache decode (743 ms of 884 ms on a 300k-item
/// catalogue) and `JSONDecoder` cannot be meaningfully sped up: the cache now stores a compact
/// binary form instead. The layout is fixed-order fields, presence bitmasks for optionals,
/// LEB128 varints (zigzag for signed integers), length-prefixed UTF-8 strings, and exact
/// bit-pattern doubles — no validation or re-encoding loss anywhere.
///
/// Every payload opens with a per-segment **string table**: each distinct string is written once
/// and referenced by index. Category ids, tags, genres, stream-URL hosts and the source id repeat
/// across thousands of items per segment, so the table both shrinks the payload and — more
/// importantly — means each repeated string is instantiated exactly once at decode instead of once
/// per item. String *lists* (tags, genres, cast) and header dictionaries are tabled the same way,
/// which reproduces the instance sharing `shareRepeatedValues()` used to pay for after decoding:
/// equal lists decode to the very same array value.
///
/// The decoder trusts nothing: every count is validated against the remaining byte count before
/// it can size an allocation, every read is bounds-checked, and any inconsistency fails the whole
/// segment (the cache then decodes as `nil`, exactly like corrupt JSON did).
enum BinaryArchive {
    /// Canary byte opening every v2 payload. Mostly a corruption tripwire: the container version
    /// already selects the codec, but a payload that does not start here is never binary v2.
    static let codecByte: UInt8 = 0xB1

    enum DecodeError: Error {
        case corrupt
    }

    // MARK: - Writer

    /// Little-endian byte sink. `append` on `Data` is already the fast path used by
    /// `SegmentedArchive`; capacity is reserved per segment by the caller.
    struct Writer {
        private(set) var data = Data()

        mutating func reserveCapacity(_ capacity: Int) {
            data.reserveCapacity(capacity)
        }

        mutating func writeByte(_ value: UInt8) {
            data.append(value)
        }

        mutating func writeBytes(_ bytes: some Sequence<UInt8>) {
            data.append(contentsOf: bytes)
        }

        mutating func writeData(_ other: Data) {
            data.append(other)
        }

        /// LEB128 unsigned varint.
        mutating func writeVarint(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                data.append(UInt8(truncatingIfNeeded: value) | 0x80)
                value >>= 7
            }
            data.append(UInt8(truncatingIfNeeded: value))
        }

        /// Zigzag-encoded signed integer as a varint: small magnitudes stay small whatever
        /// their sign, and the full `Int` range round-trips.
        mutating func writeZigzag(_ value: Int) {
            let wide = Int64(value)
            writeVarint(UInt64(bitPattern: (wide << 1) ^ (wide >> 63)))
        }

        /// Count-prefixed integers are never negative; encoding them unsigned keeps the
        /// encoding obvious and corruption visible (a negative count cannot even be written).
        mutating func writeCount(_ count: Int) {
            writeVarint(UInt64(count))
        }

        /// Exact bit pattern, little-endian — NaN payloads, signed zeros and every
        /// representable value round-trip bit for bit.
        mutating func writeDouble(_ value: Double) {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }

        mutating func writeString(_ string: String) {
            writeVarint(UInt64(string.utf8.count))
            data.append(contentsOf: string.utf8)
        }
    }

    // MARK: - Reader

    /// Bounds-checked cursor over the payload bytes. Every multi-byte integer is assembled
    /// byte by byte: no alignment assumptions, no unaligned loads, explicit little-endian.
    struct Reader {
        let base: UnsafeRawBufferPointer
        var position = 0

        var remaining: Int { base.count - position }

        mutating func readByte() throws -> UInt8 {
            guard position < base.count else { throw DecodeError.corrupt }
            defer { position += 1 }
            return base[position]
        }

        mutating func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try readByte()
                // The 10th byte of a 64-bit varint may only carry one bit of payload:
                // anything more means the varint overflows (or never terminates).
                if shift == 63 {
                    guard byte <= 1 else { throw DecodeError.corrupt }
                    return result | UInt64(byte) << shift
                }
                result |= UInt64(byte & 0x7F) << shift
                guard byte & 0x80 != 0 else { return result }
                shift += 7
            }
        }

        mutating func readZigzag() throws -> Int {
            let unsigned = try readVarint()
            let mask = UInt64(0) &- (unsigned & 1)
            return Int(Int64(bitPattern: (unsigned >> 1) ^ mask))
        }

        /// A count about to size a loop or an allocation. Every element of every encoding
        /// costs at least one byte, so a count larger than the remaining payload is proof
        /// of corruption *before* it turns into a giant allocation.
        mutating func readCount() throws -> Int {
            let count = try readVarint()
            guard count <= UInt64(remaining) else { throw DecodeError.corrupt }
            return Int(count)
        }

        mutating func readDouble() throws -> Double {
            guard remaining >= 8 else { throw DecodeError.corrupt }
            var bits: UInt64 = 0
            for index in 0..<8 {
                bits |= UInt64(base[position + index]) << UInt64(index * 8)
            }
            position += 8
            return Double(bitPattern: bits)
        }

        /// `length` bytes as a UTF-8 string. `String(decoding:as:)` copies and validates in
        /// one pass; short strings stay inline in the `String` value itself.
        mutating func readString() throws -> String {
            let length = try readCount()
            guard length <= remaining else { throw DecodeError.corrupt }
            let slice = UnsafeRawBufferPointer(rebasing: base[position..<position + length])
            position += length
            return String(decoding: slice, as: UTF8.self)
        }

        /// Table index, or proof of corruption when it points past the table.
        mutating func readReference(tableSize: Int) throws -> Int {
            let index = try readVarint()
            guard index < UInt64(tableSize) else { throw DecodeError.corrupt }
            return Int(index)
        }

        mutating func requireEnd() throws {
            guard position == base.count else { throw DecodeError.corrupt }
        }
    }

    // MARK: - Tables

    /// Per-segment interning state. Indices are assigned in order of first use and never
    /// change once handed out, so records can be encoded in a single pass into a side buffer
    /// while the tables are still being filled; the tables are serialized ahead of them.
    ///
    /// Lists and header dictionaries are interned in their *resolved* index form: interned
    /// strings are a bijection, so `[Int]` equality is exactly `[String]` equality — equal
    /// lists share one entry, and at decode they share one array instance.
    struct Tables {
        var strings: [String] = []
        var stringIndex: [String: Int] = [:]
        var lists: [[Int]] = []
        var listIndex: [[Int]: Int] = [:]
        var dicts: [[Int: Int]] = []
        var dictIndex: [[Int: Int]: Int] = [:]

        mutating func intern(_ string: String) -> Int {
            if let existing = stringIndex[string] { return existing }
            let index = strings.count
            strings.append(string)
            stringIndex[string] = index
            return index
        }

        mutating func intern(_ list: [String]) -> Int {
            let resolved = list.map { intern($0) }
            if let existing = listIndex[resolved] { return existing }
            let index = lists.count
            lists.append(resolved)
            listIndex[resolved] = index
            return index
        }

        mutating func intern(_ dict: [String: String]) -> Int {
            var resolved: [Int: Int] = [:]
            for (key, value) in dict {
                resolved[intern(key)] = intern(value)
            }
            if let existing = dictIndex[resolved] { return existing }
            let index = dicts.count
            dicts.append(resolved)
            dictIndex[resolved] = index
            return index
        }

        mutating func write(to writer: inout Writer) {
            writer.writeCount(strings.count)
            for string in strings { writer.writeString(string) }
            writer.writeCount(lists.count)
            for list in lists {
                writer.writeCount(list.count)
                for element in list { writer.writeVarint(UInt64(element)) }
            }
            writer.writeCount(dicts.count)
            for dict in dicts {
                writer.writeCount(dict.count)
                // Sorted for deterministic output; dictionary equality is order-insensitive anyway.
                for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                    writer.writeVarint(UInt64(key))
                    writer.writeVarint(UInt64(value))
                }
            }
        }
    }

    /// Prologue shared by every payload: codec byte, then the three tables. Returns the
    /// materialized tables — one array lookup per reference at record decode, and equal
    /// values share one instance for free. Internal (not private) so the bench harness can
    /// measure the table phase separately.
    static func readTables(_ reader: inout Reader) throws -> (strings: [String], lists: [[String]], dicts: [[String: String]]) {
        guard try reader.readByte() == codecByte else { throw DecodeError.corrupt }
        let stringCount = try reader.readCount()
        var strings: [String] = []
        strings.reserveCapacity(stringCount)
        for _ in 0..<stringCount {
            strings.append(try reader.readString())
        }
        let listCount = try reader.readCount()
        var lists: [[String]] = []
        lists.reserveCapacity(listCount)
        for _ in 0..<listCount {
            let elementCount = try reader.readCount()
            var list: [String] = []
            list.reserveCapacity(elementCount)
            for _ in 0..<elementCount {
                list.append(strings[try reader.readReference(tableSize: strings.count)])
            }
            lists.append(list)
        }
        let dictCount = try reader.readCount()
        var dicts: [[String: String]] = []
        dicts.reserveCapacity(dictCount)
        for _ in 0..<dictCount {
            let pairCount = try reader.readCount()
            var dict: [String: String] = [:]
            for _ in 0..<pairCount {
                let key = strings[try reader.readReference(tableSize: strings.count)]
                let value = strings[try reader.readReference(tableSize: strings.count)]
                dict[key] = value
            }
            dicts.append(dict)
        }
        return (strings, lists, dicts)
    }

    // MARK: - Channels

    // Mask bits, in write order of the optional fields.
    private enum ChannelBit {
        static let number = 0, logoURL = 1, categoryID = 2, epgID = 3, alternateStreamURL = 4
        static let catchup = 5, isAdult = 6, nonCanonicalID = 7
    }

    /// Encodes one channel chunk. Record order is fixed: mask, required fields, then the
    /// optional fields in bit order. `id` is reconstructed from source/kind/nativeID like the
    /// initializer does, unless it was mutated away from that canonical form (never in
    /// practice — the bit then stores the exact raw value).
    static func encodeChannels(_ channels: ArraySlice<Channel>) -> Data {
        var tables = Tables()
        var records = Writer()
        records.reserveCapacity(channels.count * 48)
        records.writeCount(channels.count)
        for channel in channels {
            var mask: UInt8 = 0
            if channel.number != nil { mask |= 1 << ChannelBit.number }
            if channel.$logoURL != nil { mask |= 1 << ChannelBit.logoURL }
            if channel.categoryID != nil { mask |= 1 << ChannelBit.categoryID }
            if channel.epgID != nil { mask |= 1 << ChannelBit.epgID }
            if channel.$alternateStreamURL != nil { mask |= 1 << ChannelBit.alternateStreamURL }
            if channel.catchup != nil { mask |= 1 << ChannelBit.catchup }
            if channel.isAdult { mask |= 1 << ChannelBit.isAdult }
            let canonicalID = ContentID(source: channel.sourceID, kind: .live, nativeID: channel.nativeID)
            if channel.id != canonicalID { mask |= 1 << ChannelBit.nonCanonicalID }
            records.writeByte(mask)
            records.writeVarint(UInt64(tables.intern(channel.nativeID)))
            records.writeVarint(UInt64(tables.intern(channel.name)))
            records.writeVarint(UInt64(tables.intern(channel.rawName)))
            records.writeVarint(UInt64(tables.intern(channel.$streamURL)))
            records.writeVarint(UInt64(tables.intern(channel.sourceID.rawValue)))
            records.writeVarint(UInt64(tables.intern(channel.tags)))
            records.writeVarint(UInt64(tables.intern(channel.httpHeaders)))
            records.writeByte(UInt8(channel.quality.rawValue))
            if let number = channel.number { records.writeZigzag(number) }
            if let logo = channel.$logoURL { records.writeVarint(UInt64(tables.intern(logo))) }
            if let category = channel.categoryID { records.writeVarint(UInt64(tables.intern(category))) }
            if let epg = channel.epgID { records.writeVarint(UInt64(tables.intern(epg))) }
            if let alternate = channel.$alternateStreamURL { records.writeVarint(UInt64(tables.intern(alternate))) }
            if let catchup = channel.catchup {
                records.writeByte(UInt8(catchupModeValue(catchup.mode)))
                records.writeZigzag(catchup.days)
                if let template = catchup.template {
                    records.writeVarint(UInt64(tables.intern(template) + 1))
                } else {
                    records.writeVarint(0)
                }
            }
            if mask & (1 << ChannelBit.nonCanonicalID) != 0 {
                records.writeVarint(UInt64(tables.intern(channel.id.rawValue)))
            }
        }
        return finish(tables: &tables, records: records)
    }

    static func decodeChannels(_ payload: Data) -> [Channel]? {
        decode(payload) { reader, strings, lists, dicts in
            let count = try reader.readCount()
            var channels: [Channel] = []
            channels.reserveCapacity(count)
            for _ in 0..<count {
                let mask = try reader.readByte()
                let nativeID = strings[try reader.readReference(tableSize: strings.count)]
                let name = strings[try reader.readReference(tableSize: strings.count)]
                let rawName = strings[try reader.readReference(tableSize: strings.count)]
                let stream = strings[try reader.readReference(tableSize: strings.count)]
                let source = strings[try reader.readReference(tableSize: strings.count)]
                let tags = lists[try reader.readReference(tableSize: lists.count)]
                let headers = dicts[try reader.readReference(tableSize: dicts.count)]
                let qualityByte = try reader.readByte()
                guard let quality = VideoQuality(rawValue: Int(qualityByte)) else { throw DecodeError.corrupt }
                var channel = Channel(
                    sourceID: SourceID(source), nativeID: nativeID, name: name, rawName: rawName,
                    streamURL: placeholderURL, quality: quality, tags: tags, isAdult: mask & (1 << ChannelBit.isAdult) != 0,
                    httpHeaders: headers
                )
                channel.$streamURL = stream
                if mask & (1 << ChannelBit.number) != 0 { channel.number = try reader.readZigzag() }
                if mask & (1 << ChannelBit.logoURL) != 0 { channel.$logoURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << ChannelBit.categoryID) != 0 { channel.categoryID = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << ChannelBit.epgID) != 0 { channel.epgID = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << ChannelBit.alternateStreamURL) != 0 { channel.$alternateStreamURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << ChannelBit.catchup) != 0 {
                    guard let mode = catchupMode(at: try reader.readByte()) else { throw DecodeError.corrupt }
                    let days = try reader.readZigzag()
                    let templateIndex = try reader.readVarint()
                    var template: String?
                    if templateIndex > 0 {
                        guard templateIndex <= UInt64(strings.count) else { throw DecodeError.corrupt }
                        template = strings[Int(templateIndex - 1)]
                    }
                    channel.catchup = Catchup(mode: mode, days: days, template: template)
                }
                if mask & (1 << ChannelBit.nonCanonicalID) != 0 {
                    channel.id = ContentID(rawValue: strings[try reader.readReference(tableSize: strings.count)])
                }
                channels.append(channel)
            }
            return channels
        }
    }

    private static func catchupModeValue(_ mode: Catchup.Mode) -> Int {
        switch mode {
        case .xtream: 0
        case .default: 1
        case .append: 2
        case .shift: 3
        case .flussonic: 4
        }
    }

    private static func catchupMode(at value: UInt8) -> Catchup.Mode? {
        switch value {
        case 0: .xtream
        case 1: .default
        case 2: .append
        case 3: .shift
        case 4: .flussonic
        default: nil
        }
    }

    // MARK: - Movies

    private enum MovieBit {
        static let year = 0, posterURL = 1, backdropURL = 2, plot = 3, rating = 4, durationSeconds = 5
        static let director = 6, categoryID = 7, containerExtension = 8, addedAt = 9, tmdbID = 10
        static let trailerURL = 11, isAdult = 12, nonCanonicalID = 13
    }

    static func encodeMovies(_ movies: ArraySlice<Movie>) -> Data {
        var tables = Tables()
        var records = Writer()
        records.reserveCapacity(movies.count * 64)
        records.writeCount(movies.count)
        for movie in movies {
            var mask: UInt16 = 0
            if movie.year != nil { mask |= 1 << MovieBit.year }
            if movie.$posterURL != nil { mask |= 1 << MovieBit.posterURL }
            if movie.$backdropURL != nil { mask |= 1 << MovieBit.backdropURL }
            if movie.plot != nil { mask |= 1 << MovieBit.plot }
            if movie.rating != nil { mask |= 1 << MovieBit.rating }
            if movie.durationSeconds != nil { mask |= 1 << MovieBit.durationSeconds }
            if movie.director != nil { mask |= 1 << MovieBit.director }
            if movie.categoryID != nil { mask |= 1 << MovieBit.categoryID }
            if movie.containerExtension != nil { mask |= 1 << MovieBit.containerExtension }
            if movie.addedAt != nil { mask |= 1 << MovieBit.addedAt }
            if movie.tmdbID != nil { mask |= 1 << MovieBit.tmdbID }
            if movie.$trailerURL != nil { mask |= 1 << MovieBit.trailerURL }
            if movie.isAdult { mask |= 1 << MovieBit.isAdult }
            let canonicalID = ContentID(source: movie.sourceID, kind: .movie, nativeID: movie.nativeID)
            if movie.id != canonicalID { mask |= 1 << MovieBit.nonCanonicalID }
            records.writeByte(UInt8(mask & 0xFF))
            records.writeByte(UInt8(mask >> 8))
            records.writeVarint(UInt64(tables.intern(movie.nativeID)))
            records.writeVarint(UInt64(tables.intern(movie.title)))
            records.writeVarint(UInt64(tables.intern(movie.rawName)))
            records.writeVarint(UInt64(tables.intern(movie.$streamURL)))
            records.writeVarint(UInt64(tables.intern(movie.sourceID.rawValue)))
            records.writeVarint(UInt64(tables.intern(movie.genres)))
            records.writeVarint(UInt64(tables.intern(movie.cast)))
            records.writeVarint(UInt64(tables.intern(movie.tags)))
            records.writeVarint(UInt64(tables.intern(movie.httpHeaders)))
            records.writeByte(UInt8(movie.quality.rawValue))
            if let year = movie.year { records.writeZigzag(year) }
            if let poster = movie.$posterURL { records.writeVarint(UInt64(tables.intern(poster))) }
            if let backdrop = movie.$backdropURL { records.writeVarint(UInt64(tables.intern(backdrop))) }
            if let plot = movie.plot { records.writeVarint(UInt64(tables.intern(plot))) }
            if let rating = movie.rating { records.writeDouble(rating) }
            if let duration = movie.durationSeconds { records.writeZigzag(duration) }
            if let director = movie.director { records.writeVarint(UInt64(tables.intern(director))) }
            if let category = movie.categoryID { records.writeVarint(UInt64(tables.intern(category))) }
            if let container = movie.containerExtension { records.writeVarint(UInt64(tables.intern(container))) }
            if let added = movie.addedAt { records.writeDouble(added.timeIntervalSinceReferenceDate) }
            if let tmdb = movie.tmdbID { records.writeZigzag(tmdb) }
            if let trailer = movie.$trailerURL { records.writeVarint(UInt64(tables.intern(trailer))) }
            if mask & (1 << MovieBit.nonCanonicalID) != 0 {
                records.writeVarint(UInt64(tables.intern(movie.id.rawValue)))
            }
        }
        return finish(tables: &tables, records: records)
    }

    static func decodeMovies(_ payload: Data) -> [Movie]? {
        decode(payload) { reader, strings, lists, dicts in
            let count = try reader.readCount()
            var movies: [Movie] = []
            movies.reserveCapacity(count)
            for _ in 0..<count {
                let mask = UInt16(try reader.readByte()) | UInt16(try reader.readByte()) << 8
                let nativeID = strings[try reader.readReference(tableSize: strings.count)]
                let title = strings[try reader.readReference(tableSize: strings.count)]
                let rawName = strings[try reader.readReference(tableSize: strings.count)]
                let stream = strings[try reader.readReference(tableSize: strings.count)]
                let source = strings[try reader.readReference(tableSize: strings.count)]
                let genres = lists[try reader.readReference(tableSize: lists.count)]
                let cast = lists[try reader.readReference(tableSize: lists.count)]
                let tags = lists[try reader.readReference(tableSize: lists.count)]
                let headers = dicts[try reader.readReference(tableSize: dicts.count)]
                let qualityByte = try reader.readByte()
                guard let quality = VideoQuality(rawValue: Int(qualityByte)) else { throw DecodeError.corrupt }
                var movie = Movie(
                    sourceID: SourceID(source), nativeID: nativeID, title: title, rawName: rawName,
                    genres: genres, cast: cast, streamURL: placeholderURL, quality: quality, tags: tags,
                    isAdult: mask & (1 << MovieBit.isAdult) != 0, httpHeaders: headers
                )
                movie.$streamURL = stream
                if mask & (1 << MovieBit.year) != 0 { movie.year = try reader.readZigzag() }
                if mask & (1 << MovieBit.posterURL) != 0 { movie.$posterURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << MovieBit.backdropURL) != 0 { movie.$backdropURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << MovieBit.plot) != 0 { movie.plot = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << MovieBit.rating) != 0 { movie.rating = try reader.readDouble() }
                if mask & (1 << MovieBit.durationSeconds) != 0 { movie.durationSeconds = try reader.readZigzag() }
                if mask & (1 << MovieBit.director) != 0 { movie.director = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << MovieBit.categoryID) != 0 { movie.categoryID = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << MovieBit.containerExtension) != 0 { movie.containerExtension = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << MovieBit.addedAt) != 0 { movie.addedAt = Date(timeIntervalSinceReferenceDate: try reader.readDouble()) }
                if mask & (1 << MovieBit.tmdbID) != 0 { movie.tmdbID = try reader.readZigzag() }
                if mask & (1 << MovieBit.trailerURL) != 0 { movie.$trailerURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << MovieBit.nonCanonicalID) != 0 {
                    movie.id = ContentID(rawValue: strings[try reader.readReference(tableSize: strings.count)])
                }
                movies.append(movie)
            }
            return movies
        }
    }

    // MARK: - Series

    private enum SeriesBit {
        static let year = 0, posterURL = 1, backdropURL = 2, plot = 3, rating = 4, director = 5
        static let categoryID = 6, addedAt = 7, tmdbID = 8, trailerURL = 9, isAdult = 10
        static let seasons = 11, nonCanonicalID = 12
    }

    private enum SeasonBit {
        static let name = 0, posterURL = 1, overview = 2
    }

    private enum EpisodeBit {
        static let plot = 0, durationSeconds = 1, stillURL = 2, containerExtension = 3
        static let airDate = 4, rating = 5, nonCanonicalID = 6
    }

    static func encodeSeries(_ series: ArraySlice<Series>) -> Data {
        var tables = Tables()
        var records = Writer()
        records.reserveCapacity(series.count * 64)
        records.writeCount(series.count)
        for item in series {
            encodeOneSeries(item, into: &records, tables: &tables)
        }
        return finish(tables: &tables, records: records)
    }

    private static func encodeOneSeries(_ series: Series, into records: inout Writer, tables: inout Tables) {
        var mask: UInt16 = 0
        if series.year != nil { mask |= 1 << SeriesBit.year }
        if series.$posterURL != nil { mask |= 1 << SeriesBit.posterURL }
        if series.$backdropURL != nil { mask |= 1 << SeriesBit.backdropURL }
        if series.plot != nil { mask |= 1 << SeriesBit.plot }
        if series.rating != nil { mask |= 1 << SeriesBit.rating }
        if series.director != nil { mask |= 1 << SeriesBit.director }
        if series.categoryID != nil { mask |= 1 << SeriesBit.categoryID }
        if series.addedAt != nil { mask |= 1 << SeriesBit.addedAt }
        if series.tmdbID != nil { mask |= 1 << SeriesBit.tmdbID }
        if series.$trailerURL != nil { mask |= 1 << SeriesBit.trailerURL }
        if series.isAdult { mask |= 1 << SeriesBit.isAdult }
        if series.seasons != nil { mask |= 1 << SeriesBit.seasons }
        let canonicalID = ContentID(source: series.sourceID, kind: .series, nativeID: series.nativeID)
        if series.id != canonicalID { mask |= 1 << SeriesBit.nonCanonicalID }
        records.writeByte(UInt8(mask & 0xFF))
        records.writeByte(UInt8(mask >> 8))
        records.writeVarint(UInt64(tables.intern(series.nativeID)))
        records.writeVarint(UInt64(tables.intern(series.title)))
        records.writeVarint(UInt64(tables.intern(series.rawName)))
        records.writeVarint(UInt64(tables.intern(series.sourceID.rawValue)))
        records.writeVarint(UInt64(tables.intern(series.genres)))
        records.writeVarint(UInt64(tables.intern(series.cast)))
        records.writeVarint(UInt64(tables.intern(series.tags)))
        records.writeByte(UInt8(series.quality.rawValue))
        if let year = series.year { records.writeZigzag(year) }
        if let poster = series.$posterURL { records.writeVarint(UInt64(tables.intern(poster))) }
        if let backdrop = series.$backdropURL { records.writeVarint(UInt64(tables.intern(backdrop))) }
        if let plot = series.plot { records.writeVarint(UInt64(tables.intern(plot))) }
        if let rating = series.rating { records.writeDouble(rating) }
        if let director = series.director { records.writeVarint(UInt64(tables.intern(director))) }
        if let category = series.categoryID { records.writeVarint(UInt64(tables.intern(category))) }
        if let added = series.addedAt { records.writeDouble(added.timeIntervalSinceReferenceDate) }
        if let tmdb = series.tmdbID { records.writeZigzag(tmdb) }
        if let trailer = series.$trailerURL { records.writeVarint(UInt64(tables.intern(trailer))) }
        if let seasons = series.seasons {
            records.writeCount(seasons.count)
            for season in seasons {
                encodeSeason(season, into: &records, tables: &tables)
            }
        }
        if mask & (1 << SeriesBit.nonCanonicalID) != 0 {
            records.writeVarint(UInt64(tables.intern(series.id.rawValue)))
        }
    }

    private static func encodeSeason(_ season: Season, into records: inout Writer, tables: inout Tables) {
        var mask: UInt8 = 0
        if season.name != nil { mask |= 1 << SeasonBit.name }
        if season.posterURL != nil { mask |= 1 << SeasonBit.posterURL }
        if season.overview != nil { mask |= 1 << SeasonBit.overview }
        records.writeByte(mask)
        records.writeZigzag(season.number)
        records.writeCount(season.episodes.count)
        if let name = season.name { records.writeVarint(UInt64(tables.intern(name))) }
        // `posterURL` is a plain `URL?` here (not compact): stored as its absolute string,
        // exactly like JSON — the decoder reparses it and fails the segment when invalid,
        // which is what `JSONDecoder` did.
        if let poster = season.posterURL { records.writeVarint(UInt64(tables.intern(poster.absoluteString))) }
        if let overview = season.overview { records.writeVarint(UInt64(tables.intern(overview))) }
        for episode in season.episodes {
            encodeEpisode(episode, into: &records, tables: &tables)
        }
    }

    private static func encodeEpisode(_ episode: Episode, into records: inout Writer, tables: inout Tables) {
        var mask: UInt8 = 0
        if episode.plot != nil { mask |= 1 << EpisodeBit.plot }
        if episode.durationSeconds != nil { mask |= 1 << EpisodeBit.durationSeconds }
        if episode.$stillURL != nil { mask |= 1 << EpisodeBit.stillURL }
        if episode.containerExtension != nil { mask |= 1 << EpisodeBit.containerExtension }
        if episode.airDate != nil { mask |= 1 << EpisodeBit.airDate }
        if episode.rating != nil { mask |= 1 << EpisodeBit.rating }
        let canonicalID = ContentID(source: episode.sourceID, kind: .episode, nativeID: episode.nativeID)
        if episode.id != canonicalID { mask |= 1 << EpisodeBit.nonCanonicalID }
        records.writeByte(mask)
        records.writeVarint(UInt64(tables.intern(episode.nativeID)))
        records.writeVarint(UInt64(tables.intern(episode.title)))
        records.writeVarint(UInt64(tables.intern(episode.$streamURL)))
        records.writeVarint(UInt64(tables.intern(episode.sourceID.rawValue)))
        records.writeVarint(UInt64(tables.intern(episode.seriesID.rawValue)))
        records.writeVarint(UInt64(tables.intern(episode.httpHeaders)))
        records.writeZigzag(episode.season)
        records.writeZigzag(episode.number)
        if let plot = episode.plot { records.writeVarint(UInt64(tables.intern(plot))) }
        if let duration = episode.durationSeconds { records.writeZigzag(duration) }
        if let still = episode.$stillURL { records.writeVarint(UInt64(tables.intern(still))) }
        if let container = episode.containerExtension { records.writeVarint(UInt64(tables.intern(container))) }
        if let airDate = episode.airDate { records.writeDouble(airDate.timeIntervalSinceReferenceDate) }
        if let rating = episode.rating { records.writeDouble(rating) }
        if mask & (1 << EpisodeBit.nonCanonicalID) != 0 {
            records.writeVarint(UInt64(tables.intern(episode.id.rawValue)))
        }
    }

    static func decodeSeries(_ payload: Data) -> [Series]? {
        decode(payload) { reader, strings, lists, dicts in
            let count = try reader.readCount()
            var seriesList: [Series] = []
            seriesList.reserveCapacity(count)
            for _ in 0..<count {
                seriesList.append(try decodeOneSeries(&reader, strings: strings, lists: lists, dicts: dicts))
            }
            return seriesList
        }
    }

    private static func decodeOneSeries(_ reader: inout Reader, strings: [String], lists: [[String]], dicts: [[String: String]]) throws -> Series {
        let mask = UInt16(try reader.readByte()) | UInt16(try reader.readByte()) << 8
        let nativeID = strings[try reader.readReference(tableSize: strings.count)]
        let title = strings[try reader.readReference(tableSize: strings.count)]
        let rawName = strings[try reader.readReference(tableSize: strings.count)]
        let source = strings[try reader.readReference(tableSize: strings.count)]
        let genres = lists[try reader.readReference(tableSize: lists.count)]
        let cast = lists[try reader.readReference(tableSize: lists.count)]
        let tags = lists[try reader.readReference(tableSize: lists.count)]
        let qualityByte = try reader.readByte()
        guard let quality = VideoQuality(rawValue: Int(qualityByte)) else { throw DecodeError.corrupt }
        var series = Series(
            sourceID: SourceID(source), nativeID: nativeID, title: title, rawName: rawName,
            genres: genres, cast: cast, quality: quality, tags: tags,
            isAdult: mask & (1 << SeriesBit.isAdult) != 0
        )
        if mask & (1 << SeriesBit.year) != 0 { series.year = try reader.readZigzag() }
        if mask & (1 << SeriesBit.posterURL) != 0 { series.$posterURL = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << SeriesBit.backdropURL) != 0 { series.$backdropURL = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << SeriesBit.plot) != 0 { series.plot = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << SeriesBit.rating) != 0 { series.rating = try reader.readDouble() }
        if mask & (1 << SeriesBit.director) != 0 { series.director = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << SeriesBit.categoryID) != 0 { series.categoryID = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << SeriesBit.addedAt) != 0 { series.addedAt = Date(timeIntervalSinceReferenceDate: try reader.readDouble()) }
        if mask & (1 << SeriesBit.tmdbID) != 0 { series.tmdbID = try reader.readZigzag() }
        if mask & (1 << SeriesBit.trailerURL) != 0 { series.$trailerURL = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << SeriesBit.seasons) != 0 {
            let seasonCount = try reader.readCount()
            var seasons: [Season] = []
            seasons.reserveCapacity(seasonCount)
            for _ in 0..<seasonCount {
                seasons.append(try decodeSeason(&reader, strings: strings, dicts: dicts))
            }
            series.seasons = seasons
        }
        if mask & (1 << SeriesBit.nonCanonicalID) != 0 {
            series.id = ContentID(rawValue: strings[try reader.readReference(tableSize: strings.count)])
        }
        return series
    }

    private static func decodeSeason(_ reader: inout Reader, strings: [String], dicts: [[String: String]]) throws -> Season {
        let mask = try reader.readByte()
        let number = try reader.readZigzag()
        let episodeCount = try reader.readCount()
        var season = Season(number: number, episodes: [])
        if mask & (1 << SeasonBit.name) != 0 { season.name = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << SeasonBit.posterURL) != 0 {
            let text = strings[try reader.readReference(tableSize: strings.count)]
            guard let url = URL(string: text) else { throw DecodeError.corrupt }
            season.posterURL = url
        }
        if mask & (1 << SeasonBit.overview) != 0 { season.overview = strings[try reader.readReference(tableSize: strings.count)] }
        var episodes: [Episode] = []
        episodes.reserveCapacity(episodeCount)
        for _ in 0..<episodeCount {
            episodes.append(try decodeEpisode(&reader, strings: strings, dicts: dicts))
        }
        season.episodes = episodes
        return season
    }

    private static func decodeEpisode(_ reader: inout Reader, strings: [String], dicts: [[String: String]]) throws -> Episode {
        let mask = try reader.readByte()
        let nativeID = strings[try reader.readReference(tableSize: strings.count)]
        let title = strings[try reader.readReference(tableSize: strings.count)]
        let stream = strings[try reader.readReference(tableSize: strings.count)]
        let source = strings[try reader.readReference(tableSize: strings.count)]
        let seriesID = strings[try reader.readReference(tableSize: strings.count)]
        let headers = dicts[try reader.readReference(tableSize: dicts.count)]
        let seasonNumber = try reader.readZigzag()
        let number = try reader.readZigzag()
        var episode = Episode(
            seriesID: ContentID(rawValue: seriesID), sourceID: SourceID(source), nativeID: nativeID,
            season: seasonNumber, number: number, title: title,
            streamURL: placeholderURL, httpHeaders: headers
        )
        episode.$streamURL = stream
        if mask & (1 << EpisodeBit.plot) != 0 { episode.plot = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << EpisodeBit.durationSeconds) != 0 { episode.durationSeconds = try reader.readZigzag() }
        if mask & (1 << EpisodeBit.stillURL) != 0 { episode.$stillURL = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << EpisodeBit.containerExtension) != 0 { episode.containerExtension = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << EpisodeBit.airDate) != 0 { episode.airDate = Date(timeIntervalSinceReferenceDate: try reader.readDouble()) }
        if mask & (1 << EpisodeBit.rating) != 0 { episode.rating = try reader.readDouble() }
        if mask & (1 << EpisodeBit.nonCanonicalID) != 0 {
            episode.id = ContentID(rawValue: strings[try reader.readReference(tableSize: strings.count)])
        }
        return episode
    }

    // MARK: - Meta

    private enum CategoryBit {
        static let isAdult = 0, nonCanonicalID = 1
    }

    private enum AccountBit {
        static let isActive = 0, isTrial = 1, expiresAt = 2, createdAt = 3
        static let maxConnections = 4, activeConnections = 5, serverTimeZone = 6, serverURL = 7
    }

    /// The meta segment shares the table machinery: categories repeat the source id and their
    /// own id prefix hundreds of times. Record order after the tables: scalar fields, the
    /// tri-state flags, categories, then the optional account.
    static func encodeMeta(_ meta: CatalogCache.Meta) -> Data {
        var tables = Tables()
        var records = Writer()
        records.writeVarint(UInt64(tables.intern(meta.sourceID.rawValue)))
        records.writeDouble(meta.fetchedAt.timeIntervalSinceReferenceDate)
        records.writeZigzag(meta.channelCount)
        records.writeZigzag(meta.movieCount)
        records.writeZigzag(meta.seriesCount)
        records.writeByte(triState(meta.titlesRefined))
        records.writeByte(triState(meta.plotsCleaned))
        records.writeCount(meta.categories.count)
        for category in meta.categories {
            var mask: UInt8 = 0
            if category.isAdult { mask |= 1 << CategoryBit.isAdult }
            let canonicalID = "\(category.sourceID.rawValue):\(category.kind.rawValue):\(category.nativeID)"
            if category.id != canonicalID { mask |= 1 << CategoryBit.nonCanonicalID }
            records.writeByte(mask)
            records.writeByte(UInt8(mediaKindValue(category.kind)))
            records.writeZigzag(category.sortIndex)
            records.writeVarint(UInt64(tables.intern(category.nativeID)))
            records.writeVarint(UInt64(tables.intern(category.name)))
            records.writeVarint(UInt64(tables.intern(category.rawName)))
            records.writeVarint(UInt64(tables.intern(category.sourceID.rawValue)))
            if mask & (1 << CategoryBit.nonCanonicalID) != 0 {
                records.writeVarint(UInt64(tables.intern(category.id)))
            }
        }
        if let account = meta.account {
            records.writeByte(1)
            encodeAccount(account, into: &records, tables: &tables)
        } else {
            records.writeByte(0)
        }
        return finish(tables: &tables, records: records)
    }

    static func decodeMeta(_ payload: Data) -> CatalogCache.Meta? {
        decode(payload) { reader, strings, lists, _ in
            let source = strings[try reader.readReference(tableSize: strings.count)]
            let fetchedAt = Date(timeIntervalSinceReferenceDate: try reader.readDouble())
            let channelCount = try reader.readZigzag()
            let movieCount = try reader.readZigzag()
            let seriesCount = try reader.readZigzag()
            let titlesRefined = try boolTriState(reader.readByte())
            let plotsCleaned = try boolTriState(reader.readByte())
            let categoryCount = try reader.readCount()
            var categories: [PrismCore.Category] = []
            categories.reserveCapacity(categoryCount)
            for _ in 0..<categoryCount {
                let mask = try reader.readByte()
                guard let kind = mediaKind(at: try reader.readByte()) else { throw DecodeError.corrupt }
                let sortIndex = try reader.readZigzag()
                let nativeID = strings[try reader.readReference(tableSize: strings.count)]
                let name = strings[try reader.readReference(tableSize: strings.count)]
                let rawName = strings[try reader.readReference(tableSize: strings.count)]
                let categorySource = strings[try reader.readReference(tableSize: strings.count)]
                var category = PrismCore.Category(
                    sourceID: SourceID(categorySource), kind: kind, nativeID: nativeID,
                    name: name, rawName: rawName, isAdult: mask & (1 << CategoryBit.isAdult) != 0, sortIndex: sortIndex
                )
                if mask & (1 << CategoryBit.nonCanonicalID) != 0 {
                    category.id = strings[try reader.readReference(tableSize: strings.count)]
                }
                categories.append(category)
            }
            var account: XtreamAccount?
            if try reader.readByte() == 1 {
                account = try decodeAccount(&reader, strings: strings, lists: lists)
            }
            return CatalogCache.Meta(
                sourceID: SourceID(source), categories: categories, account: account, fetchedAt: fetchedAt,
                channelCount: channelCount, movieCount: movieCount, seriesCount: seriesCount,
                titlesRefined: titlesRefined, plotsCleaned: plotsCleaned
            )
        }
    }

    private static func encodeAccount(_ account: XtreamAccount, into records: inout Writer, tables: inout Tables) {
        var mask: UInt8 = 0
        if account.isActive { mask |= 1 << AccountBit.isActive }
        if account.isTrial { mask |= 1 << AccountBit.isTrial }
        if account.expiresAt != nil { mask |= 1 << AccountBit.expiresAt }
        if account.createdAt != nil { mask |= 1 << AccountBit.createdAt }
        if account.maxConnections != nil { mask |= 1 << AccountBit.maxConnections }
        if account.activeConnections != nil { mask |= 1 << AccountBit.activeConnections }
        if account.serverTimeZone != nil { mask |= 1 << AccountBit.serverTimeZone }
        if account.serverURL != nil { mask |= 1 << AccountBit.serverURL }
        records.writeByte(mask)
        records.writeVarint(UInt64(tables.intern(account.username)))
        records.writeVarint(UInt64(tables.intern(account.status)))
        records.writeVarint(UInt64(tables.intern(account.allowedOutputFormats)))
        if let expires = account.expiresAt { records.writeDouble(expires.timeIntervalSinceReferenceDate) }
        if let created = account.createdAt { records.writeDouble(created.timeIntervalSinceReferenceDate) }
        if let max = account.maxConnections { records.writeZigzag(max) }
        if let active = account.activeConnections { records.writeZigzag(active) }
        if let timeZone = account.serverTimeZone { records.writeVarint(UInt64(tables.intern(timeZone))) }
        // Plain `URL?` like `Season.posterURL`: the absolute string, reparsed at decode.
        if let server = account.serverURL { records.writeVarint(UInt64(tables.intern(server.absoluteString))) }
    }

    private static func decodeAccount(_ reader: inout Reader, strings: [String], lists: [[String]]) throws -> XtreamAccount {
        let mask = try reader.readByte()
        let username = strings[try reader.readReference(tableSize: strings.count)]
        let status = strings[try reader.readReference(tableSize: strings.count)]
        let formats = lists[try reader.readReference(tableSize: lists.count)]
        var account = XtreamAccount(username: username, status: status, isActive: mask & (1 << AccountBit.isActive) != 0)
        account.isTrial = mask & (1 << AccountBit.isTrial) != 0
        account.allowedOutputFormats = formats
        if mask & (1 << AccountBit.expiresAt) != 0 { account.expiresAt = Date(timeIntervalSinceReferenceDate: try reader.readDouble()) }
        if mask & (1 << AccountBit.createdAt) != 0 { account.createdAt = Date(timeIntervalSinceReferenceDate: try reader.readDouble()) }
        if mask & (1 << AccountBit.maxConnections) != 0 { account.maxConnections = try reader.readZigzag() }
        if mask & (1 << AccountBit.activeConnections) != 0 { account.activeConnections = try reader.readZigzag() }
        if mask & (1 << AccountBit.serverTimeZone) != 0 { account.serverTimeZone = strings[try reader.readReference(tableSize: strings.count)] }
        if mask & (1 << AccountBit.serverURL) != 0 {
            let text = strings[try reader.readReference(tableSize: strings.count)]
            guard let url = URL(string: text) else { throw DecodeError.corrupt }
            account.serverURL = url
        }
        return account
    }

    /// Tri-state optional booleans: archives written before the flags existed carry `nil`,
    /// and the distinction decides whether the title-refinement pass runs on decode.
    private static func triState(_ value: Bool?) -> UInt8 {
        value == nil ? 0 : value == true ? 2 : 1
    }

    private static func boolTriState(_ byte: UInt8) throws -> Bool? {
        switch byte {
        case 0: nil
        case 1: false
        case 2: true
        default: throw DecodeError.corrupt
        }
    }

    private static func mediaKindValue(_ kind: MediaKind) -> Int {
        switch kind {
        case .live: 0
        case .movie: 1
        case .series: 2
        case .episode: 3
        }
    }

    private static func mediaKind(at value: UInt8) -> MediaKind? {
        switch value {
        case 0: .live
        case 1: .movie
        case 2: .series
        case 3: .episode
        default: nil
        }
    }

    // MARK: - Assembly

    /// Never opened by a player: the required-URL inits are fed this placeholder and the exact
    /// text is assigned through the projected value right after, so decode never parses a URL.
    private static let placeholderURL = URL(fileURLWithPath: "/dev/null")

    /// Tables first, then the records buffer: references are stable from first use, so the
    /// single-pass record encoding above never needs fixups.
    private static func finish(tables: inout Tables, records: Writer) -> Data {
        var output = Writer()
        output.reserveCapacity(records.data.count + 1024)
        output.writeByte(codecByte)
        tables.write(to: &output)
        output.writeData(records.data)
        return output.data
    }

    /// Runs `body` over the payload bytes with the tables decoded, converting any corruption
    /// into `nil` — the cache treats it exactly like an unparseable JSON segment.
    private static func decode<T>(
        _ payload: Data,
        body: (inout Reader, _ strings: [String], _ lists: [[String]], _ dicts: [[String: String]]) throws -> T
    ) -> T? {
        payload.withUnsafeBytes { buffer in
            var reader = Reader(base: buffer)
            guard let tables = try? readTables(&reader),
                  let result = try? body(&reader, tables.strings, tables.lists, tables.dicts),
                  (try? reader.requireEnd()) != nil
            else { return nil }
            return result
        }
    }
}
