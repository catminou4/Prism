import Foundation
import PrismCore

/// Binary payloads of the derived, already-grouped catalog artifact.
///
/// The container is the same versioned `SegmentedArchive` as the source caches, but the
/// payload schema is independent: it stores the exact immutable `Catalog` output, not the
/// per-source inputs. Large item payloads reuse the v2 `BinaryArchive` item codecs; grouped
/// title records and the reduced index representation below use the same table interning,
/// fixed field order, exact doubles and hardened bounds-checked reader.
enum BuiltCatalogBinary {
    struct InputFingerprint: Sendable, Hashable {
        var sourceID: SourceID
        var byteCount: UInt64
        var contentHash: UInt64
    }

    struct Meta: Sendable, Hashable {
        var builderSemanticsVersion: UInt32
        var saveGeneration: UInt64
        var hideAdult: Bool
        var hiddenCategoryIDs: [String]
        var inputs: [InputFingerprint]
        var sourceCount: Int
        var movieTitleCount: Int
        var movieVariantCount: Int
        var seriesTitleCount: Int
        var seriesVariantCount: Int
        var channelGroupCount: Int
        var channelVariantCount: Int
        var categoryGroupCount: Int
    }

    struct MediaStub: Sendable {
        var title: MediaTitle
        var variantCount: Int
    }

    struct ChannelStub: Sendable {
        var group: ChannelGroup
        var variantCount: Int
    }

    struct Structure: Sendable {
        var categories: [String: PrismCore.Category] = [:]
        var liveGroups: [CategoryGroup] = []
        var movieGroups: [CategoryGroup] = []
        var seriesGroups: [CategoryGroup] = []
    }

    struct IndexPayload: Sendable {
        var hasTaggedEditions = false
        var hasMalformedMediaContentIDs = false
        var categoryLanguages: [String: Set<String>] = [:]
        /// Includes empty provider categories, which are deliberately absent from the public
        /// non-empty `CategoryGroup` arrays and therefore cannot be derived from them.
        var categoryToGroup: [String: String] = [:]
        var movieLanguageSets: [Set<String>] = []
        var seriesLanguageSets: [Set<String>] = []
        var movieLanguageIDs: [Int32] = []
        var seriesLanguageIDs: [Int32] = []
        /// Final title-index entries that cannot be derived from each title's canonical id
        /// (aliases, provider ids, and collision winners). Applying them after the canonical
        /// pass reproduces the final dictionary exactly; insertion order is irrelevant because
        /// these are the final winners, not the historical losing entries.
        var movieTitleExtras: [TitleID: Int] = [:]
        var seriesTitleExtras: [TitleID: Int] = [:]
        /// Member lists in flattened live/movie/series category-group order.
        var groupMembers: [[Int32]] = []
        var featuredMovies: [Int32] = []
        var featuredSeries: [Int32] = []
        var topRatedMovies: [Int32] = []
        var topRatedSeries: [Int32] = []
    }

    // MARK: - Local primitive helpers

    private typealias Writer = BinaryArchive.Writer
    private typealias Reader = BinaryArchive.Reader
    private typealias Tables = BinaryArchive.Tables
    private typealias DecodeError = BinaryArchive.DecodeError

    private static func finish(tables: inout Tables, records: Writer) -> Data {
        var output = Writer()
        output.reserveCapacity(records.data.count + 1_024)
        output.writeByte(BinaryArchive.codecByte)
        tables.write(to: &output)
        output.writeData(records.data)
        return output.data
    }

    private static func decode<T>(
        _ payload: Data,
        body: (inout Reader, _ strings: [String], _ lists: [[String]], _ dicts: [[String: String]]) throws -> T
    ) -> T? {
        payload.withUnsafeBytes { buffer in
            var reader = Reader(base: buffer)
            guard let tables = try? BinaryArchive.readTables(&reader),
                  let result = try? body(&reader, tables.strings, tables.lists, tables.dicts),
                  (try? reader.requireEnd()) != nil else { return nil }
            return result
        }
    }

    private static func writeUInt64(_ value: UInt64, to writer: inout Writer) {
        for shift in stride(from: 0, through: 56, by: 8) {
            writer.writeByte(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func readUInt64(_ reader: inout Reader) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 8) {
            value |= UInt64(try reader.readByte()) << UInt64(shift)
        }
        return value
    }

    /// Scalar non-negative count/position. Unlike `readCount`, this is not bounded by the
    /// remaining byte count: scalars are often the final field of a record, so such a bound
    /// would reject legitimate nonzero values. A broad hard cap still prevents corrupt data
    /// from becoming an allocation or indexing claim.
    private static func readScalarCount(_ reader: inout Reader) throws -> Int {
        let value = try reader.readVarint()
        guard value <= 10_000_000 else { throw DecodeError.corrupt }
        return Int(value)
    }

    private static func writeOptionalString(_ value: String?, tables: inout Tables, records: inout Writer) {
        if let value { records.writeVarint(UInt64(tables.intern(value) + 1)) } else { records.writeVarint(0) }
    }

    private static func readOptionalString(_ reader: inout Reader, strings: [String]) throws -> String? {
        let index = try reader.readVarint()
        guard index > 0 else { return nil }
        guard index <= UInt64(strings.count) else { throw DecodeError.corrupt }
        return strings[Int(index - 1)]
    }

    private static func writeDataBytes(_ value: Data, records: inout Writer) {
        records.writeCount(value.count)
        records.writeData(value)
    }

    private static func readDataBytes(_ reader: inout Reader) throws -> Data {
        let count = try reader.readCount()
        guard count <= reader.remaining else { throw DecodeError.corrupt }
        let slice = UnsafeRawBufferPointer(rebasing: reader.base[reader.position..<reader.position + count])
        reader.position += count
        return Data(slice)
    }

    private static func mediaKindValue(_ kind: MediaKind) -> UInt8 {
        switch kind {
        case .live: 0
        case .movie: 1
        case .series: 2
        case .episode: 3
        }
    }

    private static func mediaKind(at value: UInt8) throws -> MediaKind {
        switch value {
        case 0: .live
        case 1: .movie
        case 2: .series
        case 3: .episode
        default: throw DecodeError.corrupt
        }
    }

    private static func sourceKindValue(_ kind: SourceKind) -> UInt8 {
        switch kind {
        case .xtream: 0
        case .m3uURL: 1
        case .m3uFile: 2
        }
    }

    private static func sourceKind(at value: UInt8) throws -> SourceKind {
        switch value {
        case 0: .xtream
        case 1: .m3uURL
        case 2: .m3uFile
        default: throw DecodeError.corrupt
        }
    }

    private static func writeSortedSet(_ set: Set<String>, tables: inout Tables, records: inout Writer) {
        records.writeVarint(UInt64(tables.intern(set.sorted())))
    }

    private static func readStringSet(_ list: [String]) throws -> Set<String> {
        let set = Set(list)
        guard set.count == list.count else { throw DecodeError.corrupt }
        return set
    }

    // MARK: - Meta

    static func encodeMeta(_ meta: Meta) -> Data {
        var tables = Tables()
        var records = Writer()
        records.writeVarint(UInt64(meta.builderSemanticsVersion))
        writeUInt64(meta.saveGeneration, to: &records)
        records.writeByte(meta.hideAdult ? 1 : 0)
        records.writeCount(meta.hiddenCategoryIDs.count)
        for id in meta.hiddenCategoryIDs { records.writeVarint(UInt64(tables.intern(id))) }
        records.writeCount(meta.inputs.count)
        for input in meta.inputs {
            records.writeVarint(UInt64(tables.intern(input.sourceID.rawValue)))
            writeUInt64(input.byteCount, to: &records)
            writeUInt64(input.contentHash, to: &records)
        }
        for count in [
            meta.sourceCount, meta.movieTitleCount, meta.movieVariantCount,
            meta.seriesTitleCount, meta.seriesVariantCount, meta.channelGroupCount,
            meta.channelVariantCount, meta.categoryGroupCount,
        ] { records.writeCount(count) }
        return finish(tables: &tables, records: records)
    }

    static func decodeMeta(_ payload: Data) -> Meta? {
        decode(payload) { reader, strings, _, _ in
            let semantics = try reader.readVarint()
            guard semantics <= UInt64(UInt32.max) else { throw DecodeError.corrupt }
            let generation = try readUInt64(&reader)
            let hide = try reader.readByte()
            guard hide <= 1 else { throw DecodeError.corrupt }
            let hiddenCount = try reader.readCount()
            var hidden: [String] = []
            hidden.reserveCapacity(hiddenCount)
            for _ in 0..<hiddenCount { hidden.append(strings[try reader.readReference(tableSize: strings.count)]) }
            let inputCount = try reader.readCount()
            var inputs: [InputFingerprint] = []
            inputs.reserveCapacity(inputCount)
            for _ in 0..<inputCount {
                let source = strings[try reader.readReference(tableSize: strings.count)]
                let byteCount = try readUInt64(&reader)
                let hash = try readUInt64(&reader)
                inputs.append(InputFingerprint(
                    sourceID: SourceID(source), byteCount: byteCount, contentHash: hash
                ))
            }
            func count() throws -> Int { try readScalarCount(&reader) }
            return Meta(
                builderSemanticsVersion: UInt32(semantics), saveGeneration: generation,
                hideAdult: hide == 1, hiddenCategoryIDs: hidden, inputs: inputs,
                sourceCount: try count(), movieTitleCount: try count(), movieVariantCount: try count(),
                seriesTitleCount: try count(), seriesVariantCount: try count(),
                channelGroupCount: try count(), channelVariantCount: try count(), categoryGroupCount: try count()
            )
        }
    }

    // MARK: - Sources

    private enum SourceBit {
        static let serverURL = 0, username = 1, fileBookmark = 2, epgURL = 3, userAgent = 4
        static let preferHLS = 5, isEnabled = 6, lastRefreshedAt = 7
    }

    static func encodeSources(_ sources: [Source]) -> Data {
        var tables = Tables()
        var records = Writer()
        records.writeCount(sources.count)
        for source in sources {
            var mask: UInt8 = 0
            if source.serverURL != nil { mask |= 1 << SourceBit.serverURL }
            if source.username != nil { mask |= 1 << SourceBit.username }
            if source.fileBookmark != nil { mask |= 1 << SourceBit.fileBookmark }
            if source.epgURL != nil { mask |= 1 << SourceBit.epgURL }
            if source.userAgent != nil { mask |= 1 << SourceBit.userAgent }
            if source.preferHLSForLive { mask |= 1 << SourceBit.preferHLS }
            if source.isEnabled { mask |= 1 << SourceBit.isEnabled }
            if source.lastRefreshedAt != nil { mask |= 1 << SourceBit.lastRefreshedAt }
            records.writeByte(mask)
            records.writeVarint(UInt64(tables.intern(source.id.rawValue)))
            records.writeVarint(UInt64(tables.intern(source.name)))
            records.writeByte(sourceKindValue(source.kind))
            records.writeByte(UInt8(source.tint.rawValue))
            records.writeDouble(source.epgTimeShiftHours)
            records.writeDouble(source.createdAt.timeIntervalSinceReferenceDate)
            writeOptionalString(source.serverURL?.absoluteString, tables: &tables, records: &records)
            writeOptionalString(source.username, tables: &tables, records: &records)
            if let bookmark = source.fileBookmark { records.writeByte(1); writeDataBytes(bookmark, records: &records) } else { records.writeByte(0) }
            writeOptionalString(source.epgURL?.absoluteString, tables: &tables, records: &records)
            writeOptionalString(source.userAgent, tables: &tables, records: &records)
            if let refreshed = source.lastRefreshedAt { records.writeDouble(refreshed.timeIntervalSinceReferenceDate) }
        }
        return finish(tables: &tables, records: records)
    }

    static func decodeSources(_ payload: Data) -> [Source]? {
        decode(payload) { reader, strings, _, _ in
            let count = try reader.readCount()
            var sources: [Source] = []
            sources.reserveCapacity(count)
            for _ in 0..<count {
                let mask = try reader.readByte()
                let id = strings[try reader.readReference(tableSize: strings.count)]
                let name = strings[try reader.readReference(tableSize: strings.count)]
                let kind = try sourceKind(at: reader.readByte())
                let tintByte = try reader.readByte()
                guard let tint = SourceTint(rawValue: Int(tintByte)) else { throw DecodeError.corrupt }
                let shift = try reader.readDouble()
                let created = Date(timeIntervalSinceReferenceDate: try reader.readDouble())
                var source = Source(
                    id: SourceID(id), name: name, kind: kind,
                    epgTimeShiftHours: shift,
                    preferHLSForLive: mask & (1 << SourceBit.preferHLS) != 0,
                    tint: tint,
                    isEnabled: mask & (1 << SourceBit.isEnabled) != 0,
                    createdAt: created
                )
                if mask & (1 << SourceBit.serverURL) != 0 {
                    guard let text = try readOptionalString(&reader, strings: strings), let url = URL(string: text) else { throw DecodeError.corrupt }
                    source.serverURL = url
                } else { _ = try readOptionalString(&reader, strings: strings) }
                source.username = try readOptionalString(&reader, strings: strings)
                let hasBookmark = try reader.readByte()
                guard hasBookmark <= 1 else { throw DecodeError.corrupt }
                if hasBookmark == 1 { source.fileBookmark = try readDataBytes(&reader) }
                if mask & (1 << SourceBit.epgURL) != 0 {
                    guard let text = try readOptionalString(&reader, strings: strings), let url = URL(string: text) else { throw DecodeError.corrupt }
                    source.epgURL = url
                } else { _ = try readOptionalString(&reader, strings: strings) }
                source.userAgent = try readOptionalString(&reader, strings: strings)
                if mask & (1 << SourceBit.lastRefreshedAt) != 0 {
                    source.lastRefreshedAt = Date(timeIntervalSinceReferenceDate: try reader.readDouble())
                }
                sources.append(source)
            }
            return sources
        }
    }

    // MARK: - Grouped title/channel records

    private enum TitleBit {
        static let year = 0, poster = 1, backdrop = 2, plot = 3, rating = 4, addedAt = 5, isAdult = 6
    }

    static func encodeMediaTitles(_ titles: ArraySlice<MediaTitle>, kind: MediaKind) -> Data {
        var tables = Tables()
        var records = Writer()
        records.reserveCapacity(titles.count * 32)
        records.writeCount(titles.count)
        for title in titles {
            var mask: UInt8 = 0
            if title.year != nil { mask |= 1 << TitleBit.year }
            if title.$posterURL != nil { mask |= 1 << TitleBit.poster }
            if title.$backdropURL != nil { mask |= 1 << TitleBit.backdrop }
            if title.plot != nil { mask |= 1 << TitleBit.plot }
            if title.rating != nil { mask |= 1 << TitleBit.rating }
            if title.addedAt != nil { mask |= 1 << TitleBit.addedAt }
            if title.isAdult { mask |= 1 << TitleBit.isAdult }
            records.writeByte(mask)
            records.writeVarint(UInt64(tables.intern(title.id.rawValue)))
            records.writeVarint(UInt64(tables.intern(title.title)))
            records.writeVarint(UInt64(tables.intern(title.genres)))
            writeSortedSet(title.categoryIDs, tables: &tables, records: &records)
            records.writeCount(title.variants.count)
            if let year = title.year { records.writeZigzag(year) }
            if let poster = title.$posterURL { records.writeVarint(UInt64(tables.intern(poster))) }
            if let backdrop = title.$backdropURL { records.writeVarint(UInt64(tables.intern(backdrop))) }
            if let plot = title.plot { records.writeVarint(UInt64(tables.intern(plot))) }
            if let rating = title.rating { records.writeDouble(rating) }
            if let added = title.addedAt { records.writeDouble(added.timeIntervalSinceReferenceDate) }
        }
        return finish(tables: &tables, records: records)
    }

    static func decodeMediaTitles(_ payload: Data, kind: MediaKind) -> [MediaStub]? {
        decode(payload) { reader, strings, lists, _ in
            let count = try reader.readCount()
            var result: [MediaStub] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                let mask = try reader.readByte()
                let id = strings[try reader.readReference(tableSize: strings.count)]
                let name = strings[try reader.readReference(tableSize: strings.count)]
                let genres = lists[try reader.readReference(tableSize: lists.count)]
                let categories = try readStringSet(lists[try reader.readReference(tableSize: lists.count)])
                let variantCount = try readScalarCount(&reader)
                guard variantCount > 0 else { throw DecodeError.corrupt }
                var title = MediaTitle(
                    id: TitleID(rawValue: id), kind: kind, title: name, year: nil,
                    variants: [], genres: genres, categoryIDs: categories,
                    isAdult: mask & (1 << TitleBit.isAdult) != 0
                )
                if mask & (1 << TitleBit.year) != 0 { title.year = try reader.readZigzag() }
                if mask & (1 << TitleBit.poster) != 0 { title.$posterURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << TitleBit.backdrop) != 0 { title.$backdropURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << TitleBit.plot) != 0 { title.plot = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << TitleBit.rating) != 0 { title.rating = try reader.readDouble() }
                if mask & (1 << TitleBit.addedAt) != 0 { title.addedAt = Date(timeIntervalSinceReferenceDate: try reader.readDouble()) }
                result.append(MediaStub(title: title, variantCount: variantCount))
            }
            return result
        }
    }

    private enum ChannelGroupBit {
        static let logo = 0, number = 1, epgID = 2, isAdult = 3
    }

    static func encodeChannelGroups(_ groups: ArraySlice<ChannelGroup>) -> Data {
        var tables = Tables()
        var records = Writer()
        records.reserveCapacity(groups.count * 32)
        records.writeCount(groups.count)
        for group in groups {
            var mask: UInt8 = 0
            if group.$logoURL != nil { mask |= 1 << ChannelGroupBit.logo }
            if group.number != nil { mask |= 1 << ChannelGroupBit.number }
            if group.epgID != nil { mask |= 1 << ChannelGroupBit.epgID }
            if group.isAdult { mask |= 1 << ChannelGroupBit.isAdult }
            records.writeByte(mask)
            records.writeVarint(UInt64(tables.intern(group.id)))
            records.writeVarint(UInt64(tables.intern(group.name)))
            writeSortedSet(group.categoryIDs, tables: &tables, records: &records)
            records.writeCount(group.variants.count)
            if let logo = group.$logoURL { records.writeVarint(UInt64(tables.intern(logo))) }
            if let number = group.number { records.writeZigzag(number) }
            if let epg = group.epgID { records.writeVarint(UInt64(tables.intern(epg))) }
        }
        return finish(tables: &tables, records: records)
    }

    static func decodeChannelGroups(_ payload: Data) -> [ChannelStub]? {
        decode(payload) { reader, strings, lists, _ in
            let count = try reader.readCount()
            var result: [ChannelStub] = []
            result.reserveCapacity(count)
            for _ in 0..<count {
                let mask = try reader.readByte()
                let id = strings[try reader.readReference(tableSize: strings.count)]
                let name = strings[try reader.readReference(tableSize: strings.count)]
                let categories = try readStringSet(lists[try reader.readReference(tableSize: lists.count)])
                let variantCount = try readScalarCount(&reader)
                guard variantCount > 0 else { throw DecodeError.corrupt }
                var group = ChannelGroup(
                    id: id, name: name, variants: [], categoryIDs: categories,
                    isAdult: mask & (1 << ChannelGroupBit.isAdult) != 0
                )
                if mask & (1 << ChannelGroupBit.logo) != 0 { group.$logoURL = strings[try reader.readReference(tableSize: strings.count)] }
                if mask & (1 << ChannelGroupBit.number) != 0 { group.number = try reader.readZigzag() }
                if mask & (1 << ChannelGroupBit.epgID) != 0 { group.epgID = strings[try reader.readReference(tableSize: strings.count)] }
                result.append(ChannelStub(group: group, variantCount: variantCount))
            }
            return result
        }
    }

    // MARK: - Categories and category groups

    private enum CategoryBit {
        static let isAdult = 0, nonCanonicalID = 1
    }

    private static func encodeCategory(_ category: PrismCore.Category, tables: inout Tables, records: inout Writer) {
        var mask: UInt8 = 0
        if category.isAdult { mask |= 1 << CategoryBit.isAdult }
        let canonical = "\(category.sourceID.rawValue):\(category.kind.rawValue):\(category.nativeID)"
        if category.id != canonical { mask |= 1 << CategoryBit.nonCanonicalID }
        records.writeByte(mask)
        records.writeByte(mediaKindValue(category.kind))
        records.writeZigzag(category.sortIndex)
        records.writeVarint(UInt64(tables.intern(category.nativeID)))
        records.writeVarint(UInt64(tables.intern(category.name)))
        records.writeVarint(UInt64(tables.intern(category.rawName)))
        records.writeVarint(UInt64(tables.intern(category.sourceID.rawValue)))
        if mask & (1 << CategoryBit.nonCanonicalID) != 0 { records.writeVarint(UInt64(tables.intern(category.id))) }
    }

    private static func decodeCategory(_ reader: inout Reader, strings: [String]) throws -> PrismCore.Category {
        let mask = try reader.readByte()
        let kind = try mediaKind(at: reader.readByte())
        let sort = try reader.readZigzag()
        let native = strings[try reader.readReference(tableSize: strings.count)]
        let name = strings[try reader.readReference(tableSize: strings.count)]
        let raw = strings[try reader.readReference(tableSize: strings.count)]
        let source = strings[try reader.readReference(tableSize: strings.count)]
        var category = PrismCore.Category(
            sourceID: SourceID(source), kind: kind, nativeID: native, name: name,
            rawName: raw, isAdult: mask & (1 << CategoryBit.isAdult) != 0, sortIndex: sort
        )
        if mask & (1 << CategoryBit.nonCanonicalID) != 0 {
            category.id = strings[try reader.readReference(tableSize: strings.count)]
        }
        return category
    }

    static func encodeStructure(_ structure: Structure) -> Data {
        var tables = Tables()
        var records = Writer()
        let categories = structure.categories.values.sorted { $0.id < $1.id }
        records.writeCount(categories.count)
        for category in categories { encodeCategory(category, tables: &tables, records: &records) }
        let groups = structure.liveGroups + structure.movieGroups + structure.seriesGroups
        records.writeCount(structure.liveGroups.count)
        records.writeCount(structure.movieGroups.count)
        records.writeCount(structure.seriesGroups.count)
        for group in groups {
            var mask: UInt8 = 0
            if group.isAdult { mask |= 1 }
            records.writeByte(mask)
            records.writeByte(mediaKindValue(group.kind))
            records.writeVarint(UInt64(tables.intern(group.id)))
            records.writeVarint(UInt64(tables.intern(group.name)))
            records.writeVarint(UInt64(tables.intern(group.categoryIDs)))
            records.writeCount(group.itemCount)
            records.writeZigzag(group.sortIndex)
        }
        return finish(tables: &tables, records: records)
    }

    static func decodeStructure(_ payload: Data) -> Structure? {
        decode(payload) { reader, strings, lists, _ in
            var output = Structure()
            let categoryCount = try reader.readCount()
            output.categories = Dictionary(minimumCapacity: categoryCount)
            for _ in 0..<categoryCount {
                let category = try decodeCategory(&reader, strings: strings)
                output.categories[category.id] = category
            }
            let liveCount = try reader.readCount()
            let movieCount = try reader.readCount()
            let seriesCount = try reader.readCount()
            let total = liveCount + movieCount + seriesCount
            guard total >= liveCount, total - liveCount >= movieCount else { throw DecodeError.corrupt }
            for index in 0..<total {
                let mask = try reader.readByte()
                guard mask <= 1 else { throw DecodeError.corrupt }
                let kind = try mediaKind(at: reader.readByte())
                let id = strings[try reader.readReference(tableSize: strings.count)]
                let name = strings[try reader.readReference(tableSize: strings.count)]
                let ids = lists[try reader.readReference(tableSize: lists.count)]
                let itemCount = try readScalarCount(&reader)
                let sort = try reader.readZigzag()
                let group = CategoryGroup(
                    id: id, kind: kind, name: name, categoryIDs: ids,
                    itemCount: itemCount, isAdult: mask == 1, sortIndex: sort
                )
                if index < liveCount {
                    guard kind == .live else { throw DecodeError.corrupt }
                    output.liveGroups.append(group)
                } else if index < liveCount + movieCount {
                    guard kind == .movie else { throw DecodeError.corrupt }
                    output.movieGroups.append(group)
                } else {
                    guard kind == .series else { throw DecodeError.corrupt }
                    output.seriesGroups.append(group)
                }
            }
            return output
        }
    }

    // MARK: - Reduced indexes

    private static func writeInt32(_ value: Int32, records: inout Writer) {
        records.writeZigzag(Int(value))
    }

    private static func readInt32(_ reader: inout Reader) throws -> Int32 {
        let value = try reader.readZigzag()
        guard value >= Int(Int32.min), value <= Int(Int32.max) else { throw DecodeError.corrupt }
        return Int32(value)
    }

    private static func writeIndexArray(_ values: [Int32], records: inout Writer) {
        records.writeCount(values.count)
        for value in values { writeInt32(value, records: &records) }
    }

    private static func readIndexArray(_ reader: inout Reader) throws -> [Int32] {
        let count = try reader.readCount()
        var values: [Int32] = []
        values.reserveCapacity(count)
        for _ in 0..<count { values.append(try readInt32(&reader)) }
        return values
    }

    private static func writeLanguageSets(_ sets: [Set<String>], tables: inout Tables, records: inout Writer) {
        records.writeCount(sets.count)
        for set in sets { writeSortedSet(set, tables: &tables, records: &records) }
    }

    private static func readLanguageSets(_ reader: inout Reader, lists: [[String]]) throws -> [Set<String>] {
        let count = try reader.readCount()
        var sets: [Set<String>] = []
        sets.reserveCapacity(count)
        for _ in 0..<count { sets.append(try readStringSet(lists[try reader.readReference(tableSize: lists.count)])) }
        return sets
    }

    private static func writeTitleExtras(_ entries: [TitleID: Int], tables: inout Tables, records: inout Writer) {
        let sorted = entries.sorted { $0.key.rawValue < $1.key.rawValue }
        records.writeCount(sorted.count)
        for (key, position) in sorted {
            records.writeVarint(UInt64(tables.intern(key.rawValue)))
            records.writeCount(position)
        }
    }

    private static func readTitleExtras(_ reader: inout Reader, strings: [String]) throws -> [TitleID: Int] {
        let count = try reader.readCount()
        var result: [TitleID: Int] = Dictionary(minimumCapacity: count)
        for _ in 0..<count {
            let key = strings[try reader.readReference(tableSize: strings.count)]
            result[TitleID(rawValue: key)] = try readScalarCount(&reader)
        }
        guard result.count == count else { throw DecodeError.corrupt }
        return result
    }

    static func encodeIndexes(_ payload: IndexPayload) -> Data {
        var tables = Tables()
        var records = Writer()
        records.writeByte((payload.hasTaggedEditions ? 1 : 0) | (payload.hasMalformedMediaContentIDs ? 2 : 0))
        let languages = payload.categoryLanguages.sorted { $0.key < $1.key }
        records.writeCount(languages.count)
        for (key, set) in languages {
            records.writeVarint(UInt64(tables.intern(key)))
            writeSortedSet(set, tables: &tables, records: &records)
        }
        let categoryMap = payload.categoryToGroup.sorted { $0.key < $1.key }
        records.writeCount(categoryMap.count)
        for (key, group) in categoryMap {
            records.writeVarint(UInt64(tables.intern(key)))
            records.writeVarint(UInt64(tables.intern(group)))
        }
        writeLanguageSets(payload.movieLanguageSets, tables: &tables, records: &records)
        writeLanguageSets(payload.seriesLanguageSets, tables: &tables, records: &records)
        records.writeCount(payload.movieLanguageIDs.count)
        for id in payload.movieLanguageIDs { writeInt32(id, records: &records) }
        records.writeCount(payload.seriesLanguageIDs.count)
        for id in payload.seriesLanguageIDs { writeInt32(id, records: &records) }
        writeTitleExtras(payload.movieTitleExtras, tables: &tables, records: &records)
        writeTitleExtras(payload.seriesTitleExtras, tables: &tables, records: &records)
        records.writeCount(payload.groupMembers.count)
        for members in payload.groupMembers { writeIndexArray(members, records: &records) }
        writeIndexArray(payload.featuredMovies, records: &records)
        writeIndexArray(payload.featuredSeries, records: &records)
        writeIndexArray(payload.topRatedMovies, records: &records)
        writeIndexArray(payload.topRatedSeries, records: &records)
        return finish(tables: &tables, records: records)
    }

    static func decodeIndexes(_ payload: Data) -> IndexPayload? {
        decode(payload) { reader, strings, lists, _ in
            let flags = try reader.readByte()
            guard flags <= 3 else { throw DecodeError.corrupt }
            var output = IndexPayload()
            output.hasTaggedEditions = flags & 1 != 0
            output.hasMalformedMediaContentIDs = flags & 2 != 0
            let languageCount = try reader.readCount()
            output.categoryLanguages = Dictionary(minimumCapacity: languageCount)
            for _ in 0..<languageCount {
                let key = strings[try reader.readReference(tableSize: strings.count)]
                output.categoryLanguages[key] = try readStringSet(lists[try reader.readReference(tableSize: lists.count)])
            }
            let categoryMapCount = try reader.readCount()
            output.categoryToGroup = Dictionary(minimumCapacity: categoryMapCount)
            for _ in 0..<categoryMapCount {
                let key = strings[try reader.readReference(tableSize: strings.count)]
                let group = strings[try reader.readReference(tableSize: strings.count)]
                output.categoryToGroup[key] = group
            }
            output.movieLanguageSets = try readLanguageSets(&reader, lists: lists)
            output.seriesLanguageSets = try readLanguageSets(&reader, lists: lists)
            let movieLanguageCount = try reader.readCount()
            output.movieLanguageIDs.reserveCapacity(movieLanguageCount)
            for _ in 0..<movieLanguageCount { output.movieLanguageIDs.append(try readInt32(&reader)) }
            let seriesLanguageCount = try reader.readCount()
            output.seriesLanguageIDs.reserveCapacity(seriesLanguageCount)
            for _ in 0..<seriesLanguageCount { output.seriesLanguageIDs.append(try readInt32(&reader)) }
            output.movieTitleExtras = try readTitleExtras(&reader, strings: strings)
            output.seriesTitleExtras = try readTitleExtras(&reader, strings: strings)
            let memberGroupCount = try reader.readCount()
            output.groupMembers.reserveCapacity(memberGroupCount)
            for _ in 0..<memberGroupCount { output.groupMembers.append(try readIndexArray(&reader)) }
            output.featuredMovies = try readIndexArray(&reader)
            output.featuredSeries = try readIndexArray(&reader)
            output.topRatedMovies = try readIndexArray(&reader)
            output.topRatedSeries = try readIndexArray(&reader)
            return output
        }
    }

    // MARK: - Assembly validation

    private static func validPositions(_ values: [Int32], count: Int, unique: Bool) -> Bool {
        if unique, Set(values).count != values.count { return false }
        return values.allSatisfy { $0 >= 0 && Int($0) < count }
    }

    /// Reassembles the immutable catalog, rejecting structurally inconsistent artifacts before
    /// any index can be out of range. Everything that can be derived from the ordered object
    /// graph is rebuilt here; only information lost in that graph was stored in `indexPayload`.
    static func assemble(
        sources: [Source], movieStubs: [MediaStub], movies: [Movie], seriesStubs: [MediaStub], series: [Series],
        channelStubs: [ChannelStub], channels: [Channel], structure: Structure, indexPayload: IndexPayload
    ) -> Catalog? {
        guard !indexPayload.movieLanguageSets.isEmpty, !indexPayload.seriesLanguageSets.isEmpty,
              indexPayload.movieLanguageSets.first == [], indexPayload.seriesLanguageSets.first == [],
              indexPayload.movieLanguageIDs.count == movies.count,
              indexPayload.seriesLanguageIDs.count == series.count,
              validPositions(indexPayload.featuredMovies, count: movieStubs.count, unique: true),
              validPositions(indexPayload.featuredSeries, count: seriesStubs.count, unique: true),
              validPositions(indexPayload.topRatedMovies, count: movieStubs.count, unique: true),
              validPositions(indexPayload.topRatedSeries, count: seriesStubs.count, unique: true)
        else { return nil }

        var indexes = Catalog.Indexes()
        indexes.hasTaggedEditions = indexPayload.hasTaggedEditions
        indexes.hasMalformedMediaContentIDs = indexPayload.hasMalformedMediaContentIDs
        indexes.categoryLanguages = indexPayload.categoryLanguages
        indexes.categories = structure.categories
        for (index, source) in sources.enumerated() { indexes.sourceIndex[source.id] = index }

        var movieTitles: [MediaTitle] = []
        movieTitles.reserveCapacity(movieStubs.count)
        var movieTitleIndex: [TitleID: Int] = Dictionary(minimumCapacity: movieStubs.count)
        var movieEntries: [ContentID: Catalog.MediaContentIndex.Entry] = Dictionary(minimumCapacity: movies.count)
        var movieOffset = 0
        for (position, stub) in movieStubs.enumerated() {
            let end = movieOffset + stub.variantCount
            guard end <= movies.count, end >= movieOffset else { return nil }
            var title = stub.title
            var variants: [MediaVariant] = []
            variants.reserveCapacity(stub.variantCount)
            for offset in movieOffset..<end {
                let languageID = Int(indexPayload.movieLanguageIDs[offset])
                guard languageID >= 0, languageID < indexPayload.movieLanguageSets.count else { return nil }
                let movie = movies[offset]
                variants.append(.movie(movie))
                movieEntries[movie.id] = Catalog.MediaContentIndex.Entry(titleIndex: position, languageID: languageID)
            }
            title.variants = variants
            movieTitleIndex[title.id] = position
            movieTitles.append(title)
            movieOffset = end
        }
        guard movieOffset == movies.count else { return nil }
        for (key, position) in indexPayload.movieTitleExtras {
            guard position >= 0, position < movieTitles.count else { return nil }
            movieTitleIndex[key] = position
        }

        var seriesTitles: [MediaTitle] = []
        seriesTitles.reserveCapacity(seriesStubs.count)
        var seriesTitleIndex: [TitleID: Int] = Dictionary(minimumCapacity: seriesStubs.count)
        var seriesEntries: [ContentID: Catalog.MediaContentIndex.Entry] = Dictionary(minimumCapacity: series.count)
        var seriesOffset = 0
        for (position, stub) in seriesStubs.enumerated() {
            let end = seriesOffset + stub.variantCount
            guard end <= series.count, end >= seriesOffset else { return nil }
            var title = stub.title
            var variants: [MediaVariant] = []
            variants.reserveCapacity(stub.variantCount)
            for offset in seriesOffset..<end {
                let languageID = Int(indexPayload.seriesLanguageIDs[offset])
                guard languageID >= 0, languageID < indexPayload.seriesLanguageSets.count else { return nil }
                let item = series[offset]
                variants.append(.series(item))
                seriesEntries[item.id] = Catalog.MediaContentIndex.Entry(titleIndex: position, languageID: languageID)
            }
            title.variants = variants
            seriesTitleIndex[title.id] = position
            seriesTitles.append(title)
            seriesOffset = end
        }
        guard seriesOffset == series.count else { return nil }
        for (key, position) in indexPayload.seriesTitleExtras {
            guard position >= 0, position < seriesTitles.count else { return nil }
            seriesTitleIndex[key] = position
        }

        var channelGroups: [ChannelGroup] = []
        channelGroups.reserveCapacity(channelStubs.count)
        var channelOffset = 0
        for (position, stub) in channelStubs.enumerated() {
            let end = channelOffset + stub.variantCount
            guard end <= channels.count, end >= channelOffset else { return nil }
            var group = stub.group
            group.variants = Array(channels[channelOffset..<end])
            channelGroups.append(group)
            indexes.channelByGroupID[group.id] = position
            for offset in channelOffset..<end { indexes.channelByContent[channels[offset].id] = position }
            channelOffset = end
        }
        guard channelOffset == channels.count else { return nil }

        let allCategoryGroups = structure.liveGroups + structure.movieGroups + structure.seriesGroups
        guard indexPayload.groupMembers.count == allCategoryGroups.count else { return nil }
        for (offset, group) in structure.liveGroups.enumerated() {
            indexes.categoryGroups[group.id] = Catalog.GroupRef(kind: .live, index: offset)
        }
        for (offset, group) in structure.movieGroups.enumerated() {
            indexes.categoryGroups[group.id] = Catalog.GroupRef(kind: .movie, index: offset)
        }
        for (offset, group) in structure.seriesGroups.enumerated() {
            indexes.categoryGroups[group.id] = Catalog.GroupRef(kind: .series, index: offset)
        }
        indexes.categoryToGroup = indexPayload.categoryToGroup
        for (index, group) in allCategoryGroups.enumerated() {
            let members = indexPayload.groupMembers[index]
            guard !members.isEmpty, members.count == group.itemCount else { return nil }
            let itemCount = group.kind == .movie ? movieTitles.count : (group.kind == .series ? seriesTitles.count : channelGroups.count)
            guard validPositions(members, count: itemCount, unique: false) else { return nil }
            var previous: Int32 = -1
            for member in members {
                guard member > previous else { return nil }
                previous = member
            }
            indexes.groupMembers[group.id] = members
        }

        indexes.movieByTitleID = movieTitleIndex
        indexes.seriesByTitleID = seriesTitleIndex
        indexes.movieByContent = Catalog.MediaContentIndex(entries: movieEntries, providerLanguageSets: indexPayload.movieLanguageSets)
        indexes.seriesByContent = Catalog.MediaContentIndex(entries: seriesEntries, providerLanguageSets: indexPayload.seriesLanguageSets)
        indexes.featuredMovies = indexPayload.featuredMovies
        indexes.featuredSeries = indexPayload.featuredSeries
        indexes.topRatedMovies = indexPayload.topRatedMovies
        indexes.topRatedSeries = indexPayload.topRatedSeries

        return Catalog(
            sources: sources, channels: channelGroups, movies: movieTitles, series: seriesTitles,
            liveCategories: structure.liveGroups, movieCategories: structure.movieGroups,
            seriesCategories: structure.seriesGroups, indexes: indexes
        )
    }
}
