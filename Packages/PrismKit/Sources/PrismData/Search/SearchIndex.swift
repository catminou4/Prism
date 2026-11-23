import Foundation
import PrismCore

public struct SearchResults: Sendable {
    public var topHit: SearchHit?
    public var channels: [ChannelGroup]
    public var movies: [MediaTitle]
    public var series: [MediaTitle]

    public init(topHit: SearchHit? = nil, channels: [ChannelGroup] = [], movies: [MediaTitle] = [], series: [MediaTitle] = []) {
        self.topHit = topHit
        self.channels = channels
        self.movies = movies
        self.series = series
    }

    public static let empty = SearchResults()

    public var isEmpty: Bool { topHit == nil && channels.isEmpty && movies.isEmpty && series.isEmpty }
}

public enum SearchHit: Sendable, Hashable {
    case channel(ChannelGroup)
    case title(MediaTitle)
}

/// In-memory, case/diacritic-insensitive search over every channel, movie and series of a catalog.
///
/// Every name is folded and split into words once. Unique words are sorted bytewise so that a query
/// token resolves to a contiguous range of words by binary search; each word has a posting list of
/// entries. Queries are multi-token AND (each token must prefix-match a word of the name).
/// Ranking: exact full match > full-name prefix > all-words-prefix > substring fallback (only when
/// nothing prefix-matches); ties broken by quality, variant count, recency, then shorter names.
public final class SearchIndex: Sendable {
    let channels: [ChannelGroup]
    let movies: [MediaTitle]
    let series: [MediaTitle]

    /// Entries use the concatenated order of channels, movies, then series.
    let movieStart: Int
    let seriesStart: Int
    /// Per entry: tie-break score (quality, variants, recency, shortness), < 2^60.
    let baseScores: [UInt64]
    /// Normalized names ("word word word"), flattened; `nameOffsets.count == entryCount + 1`.
    let nameBytes: [UInt8]
    let nameOffsets: [Int32]
    /// Word ranks of every entry, flattened; `entryWordOffsets.count == entryCount + 1`.
    let entryWords: [Int32]
    let entryWordOffsets: [Int32]
    /// Unique words in bytewise order, flattened; `wordOffsets.count == wordCount + 1`.
    let wordBytes: [UInt8]
    let wordOffsets: [Int32]
    /// Per-word 64-bit signature of contained byte values (mod 64): the substring fallback
    /// skips words that cannot contain the token's first byte without calling `memmem`.
    let wordMasks: [UInt64]
    /// Entries containing each word (by rank), flattened; `postingOffsets.count == wordCount + 1`.
    let postings: [Int32]
    let postingOffsets: [Int32]

    public var entryCount: Int { baseScores.count }
    public var wordCount: Int { max(wordOffsets.count - 1, 0) }

    public static let empty = SearchIndex()
    static let minimumSubstringLength = 2

    private init() {
        channels = []; movies = []; series = []
        movieStart = 0; seriesStart = 0; baseScores = []
        nameBytes = []; nameOffsets = [0]
        entryWords = []; entryWordOffsets = [0]
        wordBytes = []; wordOffsets = [0]
        wordMasks = []
        postings = []; postingOffsets = [0]
    }

    private init(
        channels: [ChannelGroup], movies: [MediaTitle], series: [MediaTitle],
        baseScores: [UInt64],
        nameBytes: [UInt8], nameOffsets: [Int32], entryWords: [Int32], entryWordOffsets: [Int32],
        wordBytes: [UInt8], wordOffsets: [Int32], wordMasks: [UInt64], postings: [Int32], postingOffsets: [Int32]
    ) {
        self.channels = channels
        self.movies = movies
        self.series = series
        self.movieStart = channels.count
        self.seriesStart = channels.count + movies.count
        self.baseScores = baseScores
        self.nameBytes = nameBytes
        self.nameOffsets = nameOffsets
        self.entryWords = entryWords
        self.entryWordOffsets = entryWordOffsets
        self.wordBytes = wordBytes
        self.wordOffsets = wordOffsets
        self.wordMasks = wordMasks
        self.postings = postings
        self.postingOffsets = postingOffsets
    }

    // MARK: - Build

    private struct Source: Sendable {
        var name: String
        var extraWord: String?
        var baseScore: UInt64
        var alternateNames: Set<String> = []
    }

    /// Per-chunk output: names plus chunk-local word ids (deduplicated per entry).
    private struct Chunk: Sendable {
        var start: Int
        var nameBytes: [UInt8] = []
        var nameLengths: [Int32] = []
        /// Unique words of the chunk, indexed by local id.
        var localWords: [String] = []
        /// Local word ids of every entry, flattened.
        var entryWords: [Int32] = []
        var wordCounts: [Int32] = []
        var baseScores: [UInt64] = []
    }

    @concurrent
    public static func build(from catalog: Catalog, recommendations: Recommendations = .empty) async -> SearchIndex {
        let channels = catalog.channels, movies = catalog.movies, series = catalog.series
        let total = channels.count + movies.count + series.count
        guard total > 0, !Task.isCancelled else { return .empty }

        // Describe + fold + split in parallel chunks (entry order: channels, movies, series).
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunkSize = max(4_096, total / (workers * 2))
        let chunks = await withTaskGroup(of: Chunk.self) { group in
            var start = 0
            while start < total {
                let lower = start, upper = min(start + chunkSize, total)
                group.addTask {
                    guard !Task.isCancelled else { return Chunk(start: lower) }
                    return processChunk(range: lower..<upper) { entry in
                        if entry < channels.count {
                            let group = channels[entry]
                            let quality = group.variants.lazy.map(\.quality).max() ?? .unknown
                            return Source(
                                name: group.name, extraWord: nil,
                                baseScore: baseScore(quality: quality, variants: group.variants.count, addedAt: nil, nameLength: group.name.utf8.count)
                            )
                        }
                        let isMovie = entry < channels.count + movies.count
                        let index = isMovie ? entry - channels.count : entry - channels.count - movies.count
                        let title = isMovie ? movies[index] : series[index]
                        let name = recommendations.editorialCopy[title.id]?.title ?? title.title
                        var alternateNames: Set<String> = []
                        if title.title != name { alternateNames.insert(title.title) }
                        if title.variants.count > 1 {
                            for variant in title.variants where variant.title != name { alternateNames.insert(variant.title) }
                        }
                        return Source(
                            name: name, extraWord: title.year.map(String.init),
                            baseScore: baseScore(quality: title.bestQuality, variants: title.variants.count, addedAt: title.addedAt, nameLength: name.utf8.count),
                            alternateNames: alternateNames
                        )
                    }
                }
                start = upper
            }
            var result: [Chunk] = []
            for await chunk in group { result.append(chunk) }
            return result.sorted { $0.start < $1.start }
        }
        guard !Task.isCancelled else { return .empty }
        let baseScores = chunks.flatMap(\.baseScores)

        // Names, global word ids (only chunk-unique words hit the shared dictionary).
        var nameBytes: [UInt8] = []
        var nameOffsets: [Int32] = [0]
        nameOffsets.reserveCapacity(total + 1)
        var wordIDs: [String: Int32] = Dictionary(minimumCapacity: total / 2)
        var uniqueWords: [String] = []
        var entryWordIDs: [Int32] = []
        entryWordIDs.reserveCapacity(total * 3)
        var entryWordOffsets: [Int32] = [0]
        entryWordOffsets.reserveCapacity(total + 1)
        for chunk in chunks {
            nameBytes.append(contentsOf: chunk.nameBytes)
            var running = nameOffsets.last ?? 0
            for length in chunk.nameLengths {
                running += length
                nameOffsets.append(running)
            }
            var globalOfLocal = [Int32](repeating: 0, count: chunk.localWords.count)
            for (local, word) in chunk.localWords.enumerated() {
                if let existing = wordIDs[word] {
                    globalOfLocal[local] = existing
                } else {
                    let id = Int32(uniqueWords.count)
                    wordIDs[word] = id
                    uniqueWords.append(word)
                    globalOfLocal[local] = id
                }
            }
            globalOfLocal.withUnsafeBufferPointer { map in
                for local in chunk.entryWords { entryWordIDs.append(map[Int(local)]) }
            }
            var cursor = entryWordOffsets.last ?? 0
            for count in chunk.wordCounts {
                cursor += count
                entryWordOffsets.append(cursor)
            }
        }

        // Flatten unique words by id, then sort ids bytewise.
        var idBytes: [UInt8] = []
        var idOffsets: [Int32] = [0]
        idOffsets.reserveCapacity(uniqueWords.count + 1)
        for word in uniqueWords {
            idBytes.append(contentsOf: word.utf8)
            idOffsets.append(Int32(idBytes.count))
        }
        var order = (0..<Int32(uniqueWords.count)).map { $0 }
        idBytes.withUnsafeBufferPointer { bytes in
            idOffsets.withUnsafeBufferPointer { offsets in
                order.sort { a, b in
                    let a0 = Int(offsets[Int(a)]), a1 = Int(offsets[Int(a) + 1])
                    let b0 = Int(offsets[Int(b)]), b1 = Int(offsets[Int(b) + 1])
                    return compareBytes(bytes, a0, a1 - a0, bytes, b0, b1 - b0) < 0
                }
            }
        }
        var rankOfID = [Int32](repeating: 0, count: uniqueWords.count)
        var wordBytes: [UInt8] = []
        wordBytes.reserveCapacity(idBytes.count)
        var wordOffsets: [Int32] = [0]
        wordOffsets.reserveCapacity(order.count + 1)
        for (rank, id) in order.enumerated() {
            rankOfID[Int(id)] = Int32(rank)
            wordBytes.append(contentsOf: idBytes[Int(idOffsets[Int(id)])..<Int(idOffsets[Int(id) + 1])])
            wordOffsets.append(Int32(wordBytes.count))
        }
        let entryWords = entryWordIDs.map { rankOfID[Int($0)] }
        guard !Task.isCancelled else { return .empty }

        // Posting lists (counting sort by rank; entries stay ascending inside each list).
        var counts = [Int32](repeating: 0, count: order.count + 1)
        for rank in entryWords { counts[Int(rank) + 1] += 1 }
        for index in 1..<counts.count { counts[index] += counts[index - 1] }
        let postingOffsets = counts
        var fill = counts
        var postings = [Int32](repeating: 0, count: entryWords.count)
        postings.withUnsafeMutableBufferPointer { out in
            fill.withUnsafeMutableBufferPointer { fill in
                entryWords.withUnsafeBufferPointer { words in
                    entryWordOffsets.withUnsafeBufferPointer { offsets in
                        for entry in 0..<total {
                            for position in Int(offsets[entry])..<Int(offsets[entry + 1]) {
                                let rank = Int(words[position])
                                out[Int(fill[rank])] = Int32(entry)
                                fill[rank] += 1
                            }
                        }
                    }
                }
            }
        }

        // Per-word byte-class signature for the substring fallback.
        var wordMasks = [UInt64](repeating: 0, count: order.count)
        for rank in 0..<order.count {
            let w0 = Int(wordOffsets[rank]), w1 = Int(wordOffsets[rank + 1])
            var mask: UInt64 = 0
            for position in w0..<w1 {
                mask |= UInt64(1) << (wordBytes[position] & 63)
            }
            wordMasks[rank] = mask
        }

        return SearchIndex(
            channels: channels, movies: movies, series: series,
            baseScores: baseScores,
            nameBytes: nameBytes, nameOffsets: nameOffsets,
            entryWords: entryWords, entryWordOffsets: entryWordOffsets,
            wordBytes: wordBytes, wordOffsets: wordOffsets, wordMasks: wordMasks,
            postings: postings, postingOffsets: postingOffsets
        )
    }

    private static func processChunk(range: Range<Int>, describe: (Int) -> Source) -> Chunk {
        var chunk = Chunk(start: range.lowerBound)
        chunk.baseScores.reserveCapacity(range.count)
        chunk.nameLengths.reserveCapacity(range.count)
        chunk.wordCounts.reserveCapacity(range.count)
        chunk.entryWords.reserveCapacity(range.count * 3)
        var localIDs: [String: Int32] = Dictionary(minimumCapacity: range.count)
        var entry: [Int32] = []
        var wordBuffer: [UInt8] = []
        wordBuffer.reserveCapacity(32)
        func localID(_ word: String) -> Int32 {
            if let id = localIDs[word] { return id }
            let id = Int32(chunk.localWords.count)
            localIDs[word] = id
            chunk.localWords.append(word)
            return id
        }
        for index in range {
            let source = describe(index)
            chunk.baseScores.append(source.baseScore)
            let start = chunk.nameBytes.count
            entry.removeAll(keepingCapacity: true)
            TextFolding.forEachWord(in: source.name, buffer: &wordBuffer) { word in
                if chunk.nameBytes.count > start { chunk.nameBytes.append(0x20) }
                chunk.nameBytes.append(contentsOf: word)
                let id = localID(String(decoding: word, as: UTF8.self))
                if !entry.contains(id) { entry.append(id) }
            }
            if let extra = source.extraWord {
                let id = localID(extra)
                if !entry.contains(id) { entry.append(id) }
            }
            for alias in source.alternateNames.sorted() {
                TextFolding.forEachWord(in: alias, buffer: &wordBuffer) { word in
                    let id = localID(String(decoding: word, as: UTF8.self))
                    if !entry.contains(id) { entry.append(id) }
                }
            }
            chunk.entryWords.append(contentsOf: entry)
            chunk.nameLengths.append(Int32(chunk.nameBytes.count - start))
            chunk.wordCounts.append(Int32(entry.count))
        }
        return chunk
    }

    static func baseScore(quality: VideoQuality, variants: Int, addedAt: Date?, nameLength: Int) -> UInt64 {
        let q = UInt64(min(max(quality.rawValue, 0), 7))
        let v = UInt64(min(max(variants, 0), 255))
        let days = addedAt.map { UInt64(min(max($0.timeIntervalSinceReferenceDate / 86_400 + 1, 0), 65_535)) } ?? 0
        let shortness = UInt64(65_535 - min(nameLength, 65_535))
        return q << 52 | v << 44 | days << 28 | shortness << 12
    }

    // MARK: - Query

    public func search(_ query: String, limit: Int = 30) -> SearchResults {
        guard limit > 0, entryCount > 0 else { return .empty }
        let tokens = TextFolding.words(ofFolded: TextFolding.fold(query))
        guard !tokens.isEmpty else { return .empty }
        var normalizedQuery: [UInt8] = []
        for (offset, token) in tokens.enumerated() {
            if offset > 0 { normalizedQuery.append(0x20) }
            normalizedQuery.append(contentsOf: token)
        }

        var top = [TopK(limit: limit), TopK(limit: limit), TopK(limit: limit)]
        withRaw { raw in
            let found = prefixSearch(raw, tokens: tokens, query: normalizedQuery, top: &top)
            if !found { substringSearch(raw, tokens: tokens, top: &top) }
        }

        let channelHits = top[0].items.map { channels[Int($0.entry)] }
        let movieHits = top[1].items.map { movies[Int($0.entry) - movieStart] }
        let seriesHits = top[2].items.map { series[Int($0.entry) - seriesStart] }

        var best: (score: UInt64, entry: Int32)?
        for kind in 0..<3 {
            guard let first = top[kind].items.first else { continue }
            if let current = best, !TopK.precedes(first, current) { continue }
            best = first
        }
        var topHit: SearchHit?
        if let best {
            let entry = Int(best.entry)
            switch kind(of: entry) {
            case 0: topHit = .channel(channels[entry])
            case 1: topHit = .title(movies[entry - movieStart])
            default: topHit = .title(series[entry - seriesStart])
            }
        }
        return SearchResults(topHit: topHit, channels: channelHits, movies: movieHits, series: seriesHits)
    }

    @inline(__always)
    private func kind(of entry: Int) -> Int {
        if entry < movieStart { return 0 }
        return entry < seriesStart ? 1 : 2
    }

    private struct Raw {
        let baseScores: UnsafeBufferPointer<UInt64>
        let nameBytes: UnsafeBufferPointer<UInt8>
        let nameOffsets: UnsafeBufferPointer<Int32>
        let entryWords: UnsafeBufferPointer<Int32>
        let entryWordOffsets: UnsafeBufferPointer<Int32>
        let wordBytes: UnsafeBufferPointer<UInt8>
        let wordOffsets: UnsafeBufferPointer<Int32>
        let wordMasks: UnsafeBufferPointer<UInt64>
        let postings: UnsafeBufferPointer<Int32>
        let postingOffsets: UnsafeBufferPointer<Int32>
        var wordCount: Int { wordOffsets.count - 1 }
        var entryCount: Int { baseScores.count }
    }

    private func withRaw(_ body: (Raw) -> Void) {
        baseScores.withUnsafeBufferPointer { baseScores in
        nameBytes.withUnsafeBufferPointer { nameBytes in
        nameOffsets.withUnsafeBufferPointer { nameOffsets in
        entryWords.withUnsafeBufferPointer { entryWords in
        entryWordOffsets.withUnsafeBufferPointer { entryWordOffsets in
        wordBytes.withUnsafeBufferPointer { wordBytes in
        wordOffsets.withUnsafeBufferPointer { wordOffsets in
        wordMasks.withUnsafeBufferPointer { wordMasks in
        postings.withUnsafeBufferPointer { postings in
        postingOffsets.withUnsafeBufferPointer { postingOffsets in
            body(Raw(
                baseScores: baseScores, nameBytes: nameBytes, nameOffsets: nameOffsets,
                entryWords: entryWords, entryWordOffsets: entryWordOffsets, wordBytes: wordBytes,
                wordOffsets: wordOffsets, wordMasks: wordMasks, postings: postings, postingOffsets: postingOffsets
            ))
        }}}}}}}}}}
    }

    /// Returns `false` when no entry prefix-matches every token.
    private func prefixSearch(_ raw: Raw, tokens: [[UInt8]], query: [UInt8], top: inout [TopK]) -> Bool {
        var ranges: [(lower: Int32, upper: Int32)] = []
        ranges.reserveCapacity(tokens.count)
        for token in tokens {
            let range = token.withUnsafeBufferPointer { prefixRange(raw, token: $0) }
            if range.lower >= range.upper { return false }
            ranges.append((Int32(range.lower), Int32(range.upper)))
        }
        // Drive with the token that has the smallest posting volume; check the remaining
        // tokens rarest-first so non-matching candidates bail out after the fewest scans.
        var driver = 0
        var smallest = Int.max
        var volumes = [Int](repeating: 0, count: ranges.count)
        for (index, range) in ranges.enumerated() {
            let volume = Int(raw.postingOffsets[Int(range.upper)] - raw.postingOffsets[Int(range.lower)])
            volumes[index] = volume
            if volume < smallest { smallest = volume; driver = index }
        }
        let others = ranges.enumerated()
            .filter { $0.offset != driver }
            .map { (volume: volumes[$0.offset], range: $0.element) }
            .sorted { $0.volume < $1.volume }
            .map(\.range)
        let driverRange = ranges[driver]
        let needsDedupe = driverRange.upper - driverRange.lower > 1

        let seen = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: needsDedupe ? raw.entryCount : 0)
        seen.initialize(repeating: 0)
        defer { seen.deallocate() }

        var found = false
        // Single-token queries (the common typing path) have no `others` to satisfy:
        // skip the per-entry word scan entirely.
        let needsWordCheck = !others.isEmpty
        query.withUnsafeBufferPointer { q in
            for rank in Int(driverRange.lower)..<Int(driverRange.upper) {
                for position in Int(raw.postingOffsets[rank])..<Int(raw.postingOffsets[rank + 1]) {
                    let entry = Int(raw.postings[position])
                    if needsDedupe {
                        if seen[entry] != 0 { continue }
                        seen[entry] = 1
                    }
                    if needsWordCheck {
                        let w0 = Int(raw.entryWordOffsets[entry]), w1 = Int(raw.entryWordOffsets[entry + 1])
                        var matchesAll = true
                        for range in others {
                            var hit = false
                            for w in w0..<w1 {
                                let r = raw.entryWords[w]
                                if r >= range.lower && r < range.upper { hit = true; break }
                            }
                            if !hit { matchesAll = false; break }
                        }
                        guard matchesAll else { continue }
                    }
                    found = true
                    let n0 = Int(raw.nameOffsets[entry]), n1 = Int(raw.nameOffsets[entry + 1])
                    var tier: UInt64 = 1
                    // First-byte prefilter: nearly every candidate fails the name-prefix
                    // check on byte 0, so `memcmp` only runs on the few survivors.
                    if n1 - n0 >= q.count, raw.nameBytes[n0] == q[0],
                       compareBytes(raw.nameBytes, n0, q.count, q, 0, q.count) == 0 {
                        tier = n1 - n0 == q.count ? 3 : 2
                    }
                    let score = tier << 60 | raw.baseScores[entry]
                    top[kind(of: entry)].offer(score: score, entry: Int32(entry))
                }
            }
        }
        return found
    }

    /// Fallback: every token must be a substring of some word of the name. Single-character tokens
    /// are too unselective for substring matching (they would hit most of the catalog): no fallback.
    private func substringSearch(_ raw: Raw, tokens: [[UInt8]], top: inout [TopK]) {
        let wordCount = raw.wordCount
        guard wordCount > 0, tokens.allSatisfy({ $0.count >= Self.minimumSubstringLength }) else { return }
        var maps: [UnsafeMutableBufferPointer<UInt8>] = []
        defer { maps.forEach { $0.deallocate() } }
        var volumes: [Int] = []
        for token in tokens {
            let map = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: wordCount)
            map.initialize(repeating: 0)
            maps.append(map)
            var volume = 0
            token.withUnsafeBufferPointer { t in
                // Necessary condition for containment: the word's byte-class mask must cover
                // every byte class the token uses, so words missing any class are skipped
                // outright without calling `memmem`.
                var needed: UInt64 = 0
                for byte in t { needed |= UInt64(1) << (byte & 63) }
                for rank in 0..<wordCount {
                    guard raw.wordMasks[rank] & needed == needed else { continue }
                    let w0 = Int(raw.wordOffsets[rank]), w1 = Int(raw.wordOffsets[rank + 1])
                    if containsBytes(raw.wordBytes, w0, w1 - w0, t) {
                        map[rank] = 1
                        volume += Int(raw.postingOffsets[rank + 1] - raw.postingOffsets[rank])
                    }
                }
            }
            if volume == 0 { return }
            volumes.append(volume)
        }
        var driver = 0
        for index in volumes.indices where volumes[index] < volumes[driver] { driver = index }

        let seen = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: raw.entryCount)
        seen.initialize(repeating: 0)
        defer { seen.deallocate() }
        let driverMap = maps[driver]
        // Single-token queries have no other token to satisfy.
        let needsWordCheck = maps.count > 1
        for rank in 0..<wordCount where driverMap[rank] != 0 {
            for position in Int(raw.postingOffsets[rank])..<Int(raw.postingOffsets[rank + 1]) {
                let entry = Int(raw.postings[position])
                if seen[entry] != 0 { continue }
                seen[entry] = 1
                guard needsWordCheck else {
                    top[kind(of: entry)].offer(score: raw.baseScores[entry], entry: Int32(entry))
                    continue
                }
                let w0 = Int(raw.entryWordOffsets[entry]), w1 = Int(raw.entryWordOffsets[entry + 1])
                var matchesAll = true
                for (index, map) in maps.enumerated() where index != driver {
                    var hit = false
                    for w in w0..<w1 where map[Int(raw.entryWords[w])] != 0 { hit = true; break }
                    if !hit { matchesAll = false; break }
                }
                guard matchesAll else { continue }
                top[kind(of: entry)].offer(score: raw.baseScores[entry], entry: Int32(entry))
            }
        }
    }

    /// Range of word ranks whose bytes start with `token`.
    private func prefixRange(_ raw: Raw, token: UnsafeBufferPointer<UInt8>) -> (lower: Int, upper: Int) {
        let count = raw.wordCount
        // First word >= token.
        var low = 0, high = count
        while low < high {
            let mid = (low + high) >> 1
            let w0 = Int(raw.wordOffsets[mid]), w1 = Int(raw.wordOffsets[mid + 1])
            if compareBytes(raw.wordBytes, w0, w1 - w0, token, 0, token.count) < 0 { low = mid + 1 } else { high = mid }
        }
        let lower = low
        // First word (from lower) that does not start with token.
        high = count
        while low < high {
            let mid = (low + high) >> 1
            let w0 = Int(raw.wordOffsets[mid]), w1 = Int(raw.wordOffsets[mid + 1])
            let hasPrefix = w1 - w0 >= token.count && compareBytes(raw.wordBytes, w0, token.count, token, 0, token.count) == 0
            if hasPrefix { low = mid + 1 } else { high = mid }
        }
        return (lower, low)
    }
}

// MARK: - Helpers

/// Bounded best-first list: score desc, then entry asc (deterministic).
struct TopK {
    let limit: Int
    var items: [(score: UInt64, entry: Int32)] = []

    init(limit: Int) {
        self.limit = limit
        items.reserveCapacity(limit + 1)
    }

    @inline(__always)
    static func precedes(_ a: (score: UInt64, entry: Int32), _ b: (score: UInt64, entry: Int32)) -> Bool {
        a.score != b.score ? a.score > b.score : a.entry < b.entry
    }

    @inline(__always)
    mutating func offer(score: UInt64, entry: Int32) {
        if items.count == limit, let last = items.last, !Self.precedes((score, entry), last) { return }
        var low = 0, high = items.count
        while low < high {
            let mid = (low + high) >> 1
            if Self.precedes(items[mid], (score, entry)) { low = mid + 1 } else { high = mid }
        }
        items.insert((score, entry), at: low)
        if items.count > limit { items.removeLast() }
    }
}

@inline(__always)
func compareBytes(
    _ a: UnsafeBufferPointer<UInt8>, _ aStart: Int, _ aCount: Int,
    _ b: UnsafeBufferPointer<UInt8>, _ bStart: Int, _ bCount: Int
) -> Int {
    let common = min(aCount, bCount)
    if common > 0, let pa = a.baseAddress, let pb = b.baseAddress {
        let result = memcmp(pa + aStart, pb + bStart, common)
        if result != 0 { return Int(result) }
    }
    return aCount - bCount
}

@inline(__always)
func containsBytes(_ haystack: UnsafeBufferPointer<UInt8>, _ start: Int, _ count: Int, _ needle: UnsafeBufferPointer<UInt8>) -> Bool {
    let n = needle.count
    guard n > 0 else { return true }
    guard count >= n, let h = haystack.baseAddress, let p = needle.baseAddress else { return false }
    // libc's vectorised search: several times faster than a byte loop over 300k+ words per keystroke.
    return memmem(h + start, count, p, n) != nil
}
