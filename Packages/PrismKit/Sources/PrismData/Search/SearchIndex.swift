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

    /// Per-chunk output: names, the chunk's unique words as a sorted flattened table, and
    /// per-entry positions into that table (deduplicated per entry, first-appearance order).
    private struct Chunk: Sendable {
        var start: Int
        var nameBytes: [UInt8] = []
        var nameLengths: [Int32] = []
        /// Unique words of the chunk in bytewise order, flattened; `sortedWordOffsets.count == words + 1`.
        var sortedWordBytes: [UInt8] = []
        var sortedWordOffsets: [Int32] = []
        /// Sorted-table positions of every entry's words, flattened.
        var entryWords: [Int32] = []
        var wordCounts: [Int32] = []
        var baseScores: [UInt64] = []

        var wordCount: Int { max(sortedWordOffsets.count - 1, 0) }
    }

    /// Mutable buffer shared across parallel tasks, each writing positions no other task
    /// touches. `Element` must be trivial (Int32/UInt64/UInt8): writes are then plain memory
    /// stores to disjoint locations — no overlapping access, no object lifetime involved.
    private struct DisjointBuffer<Element>: @unchecked Sendable {
        var buffer: UnsafeMutableBufferPointer<Element>

        var baseAddress: UnsafeMutablePointer<Element>? { buffer.baseAddress }

        @inline(__always) subscript(_ index: Int) -> Element {
            @inline(__always) _read { yield buffer[index] }
            @inline(__always) nonmutating set { buffer[index] = newValue }
        }
    }

    @concurrent
    public static func build(from catalog: Catalog, recommendations: Recommendations = .empty) async -> SearchIndex {
        let buildStart = ContinuousClock.now
        let channels = catalog.channels, movies = catalog.movies, series = catalog.series
        let total = channels.count + movies.count + series.count
        guard total > 0, !Task.isCancelled else { return .empty }

        // Describe + fold + split in parallel chunks (entry order: channels, movies, series).
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, 12))
        let chunkSize = max(4_096, total / (workers * 2))
        var chunks = await withTaskGroup(of: Chunk.self) { group in
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
        BuildProfile.mark("search describe+fold chunks (parallel)", since: buildStart)
        let assemblyStart = ContinuousClock.now

        // MARK: Parallel assembly.
        // Serial pass 1: prefix sums of the per-chunk bases (a handful of additions per chunk).
        // Parallel pass 2: each chunk copies its bytes into the final arrays at exact positions
        // and accumulates its entries' offsets — disjoint writes, deterministic positions.
        let baseScores = chunks.flatMap(\.baseScores)
        let chunkCount = chunks.count
        var wordBase: [Int] = []
        wordBase.reserveCapacity(chunkCount)
        var byteBase: [Int] = []
        byteBase.reserveCapacity(chunkCount)
        var nameByteBase: [Int] = []
        nameByteBase.reserveCapacity(chunkCount)
        var instanceBase: [Int] = []
        instanceBase.reserveCapacity(chunkCount)
        var wordsInChunk: [Int] = []
        wordsInChunk.reserveCapacity(chunkCount)
        var totalChunkWords = 0, totalBytes = 0, totalNameBytes = 0, totalInstances = 0
        for chunk in chunks {
            wordBase.append(totalChunkWords)
            byteBase.append(totalBytes)
            nameByteBase.append(totalNameBytes)
            instanceBase.append(totalInstances)
            wordsInChunk.append(chunk.wordCount)
            totalChunkWords += chunk.wordCount
            totalBytes += chunk.sortedWordBytes.count
            totalNameBytes += chunk.nameBytes.count
            totalInstances += chunk.entryWords.count
        }

        let frozenByteBase = byteBase, frozenNameByteBase = nameByteBase, frozenInstanceBase = instanceBase
        let frozenPrefixWordBase = wordBase, frozenPrefixWordsInChunk = wordsInChunk, frozenAssemblyChunks = chunks
        var allBytes = [UInt8](repeating: 0, count: totalBytes)
        var allOffsets = [Int32](repeating: 0, count: totalChunkWords + 1)
        var nameBytes = [UInt8](repeating: 0, count: totalNameBytes)
        var nameOffsets = [Int32](repeating: 0, count: total + 1)
        var entryWordOffsets = [Int32](repeating: 0, count: total + 1)
        // Round-0 runs are contiguous segments of one flat array (chunks are adjacent in
        // entry order, so their word positions are too): zero-copy slices, filled in parallel.
        var runPositions = [Int32](repeating: 0, count: totalChunkWords)
        allBytes.withUnsafeMutableBufferPointer { allBytesOut in
            allOffsets.withUnsafeMutableBufferPointer { allOffsetsOut in
                nameBytes.withUnsafeMutableBufferPointer { nameBytesOut in
                    nameOffsets.withUnsafeMutableBufferPointer { nameOffsetsOut in
                        entryWordOffsets.withUnsafeMutableBufferPointer { entryWordOffsetsOut in
                            runPositions.withUnsafeMutableBufferPointer { runPositionsOut in
                                let sharedAllBytes = DisjointBuffer(buffer: allBytesOut)
                                let sharedAllOffsets = DisjointBuffer(buffer: allOffsetsOut)
                                let sharedNameBytes = DisjointBuffer(buffer: nameBytesOut)
                                let sharedNameOffsets = DisjointBuffer(buffer: nameOffsetsOut)
                                let sharedEntryWordOffsets = DisjointBuffer(buffer: entryWordOffsetsOut)
                                let sharedRunPositions = DisjointBuffer(buffer: runPositionsOut)
                                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                                    let chunk = frozenAssemblyChunks[chunkIndex]
                                    let words = frozenPrefixWordsInChunk[chunkIndex]
                                    chunk.sortedWordBytes.withUnsafeBufferPointer { sourceBytes in
                                        if let source = sourceBytes.baseAddress, let target = sharedAllBytes.baseAddress, !sourceBytes.isEmpty {
                                            memcpy(target + frozenByteBase[chunkIndex], source, sourceBytes.count)
                                        }
                                    }
                                    // Copy every offset but the sentinel: the end of a chunk's last
                                    // word is the start of the next chunk's first word (back to back).
                                    let adjust = Int32(frozenByteBase[chunkIndex])
                                    let target = frozenPrefixWordBase[chunkIndex]
                                    chunk.sortedWordOffsets.dropLast().withUnsafeBufferPointer { sourceOffsets in
                                        for position in sourceOffsets.indices {
                                            sharedAllOffsets[target + position] = sourceOffsets[position] + adjust
                                        }
                                    }
                                    for position in 0..<words {
                                        sharedRunPositions[target + position] = Int32(target + position)
                                    }
                                    chunk.nameBytes.withUnsafeBufferPointer { sourceNames in
                                        if let source = sourceNames.baseAddress, let target = sharedNameBytes.baseAddress, !sourceNames.isEmpty {
                                            memcpy(target + frozenNameByteBase[chunkIndex], source, sourceNames.count)
                                        }
                                    }
                                    var nameCursor = Int32(frozenNameByteBase[chunkIndex])
                                    var wordCursor = Int32(frozenInstanceBase[chunkIndex])
                                    for entry in chunk.nameLengths.indices {
                                        nameCursor += chunk.nameLengths[entry]
                                        wordCursor += chunk.wordCounts[entry]
                                        sharedNameOffsets[chunk.start + entry + 1] = nameCursor
                                        sharedEntryWordOffsets[chunk.start + entry + 1] = wordCursor
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        allOffsets[totalChunkWords] = Int32(totalBytes)
        for index in chunks.indices {
            chunks[index].sortedWordBytes = []
            chunks[index].sortedWordOffsets = []
        }
        // Frozen snapshots for the parallel phases: no mutation happens past this point, and
        // concurrently-executing closures may only capture immutable bindings.
        let frozenBytes = allBytes, frozenOffsets = allOffsets, frozenWordBase = wordBase, frozenChunks = chunks
        let frozenWordsInChunk = wordsInChunk, frozenEntryOffsets = entryWordOffsets
        guard !Task.isCancelled else { return .empty }
        BuildProfile.mark("search table assembly", since: assemblyStart)
        let mergeStart = ContinuousClock.now

        // MARK: k-way merge of sorted runs into global bytewise order (deduplicating).
        // Pairwise merge rounds like `parallelSortedIndices`: pairing is positional, so the
        // result is deterministic. Equal words collapse to one copy and the dropped reference
        // records an alias to the survivor: after the final flatten, a short chain chase maps
        // every chunk position to its rank — no per-word search anywhere.
        // `alias[x] == 0` means "no alias", otherwise the aliased position plus one.
        let alias = UnsafeMutableBufferPointer<Int32>.allocate(capacity: max(totalChunkWords, 1))
        let survivorRank = UnsafeMutableBufferPointer<Int32>.allocate(capacity: max(totalChunkWords, 1))
        alias.initialize(repeating: 0)
        survivorRank.initialize(repeating: 0)
        defer { alias.deallocate(); survivorRank.deallocate() }
        let sharedAlias = DisjointBuffer(buffer: alias)
        var runs: [ArraySlice<Int32>] = []
        runs.reserveCapacity(chunkCount)
        for chunkIndex in 0..<chunkCount where wordsInChunk[chunkIndex] > 0 {
            let lower = wordBase[chunkIndex]
            runs.append(runPositions[lower..<(lower + wordsInChunk[chunkIndex])])
        }
        while runs.count > 1 {
            let current = runs
            runs = await withTaskGroup(of: (Int, ArraySlice<Int32>).self) { group in
                for pair in stride(from: 0, to: current.count, by: 2) {
                    group.addTask {
                        guard pair + 1 < current.count, !Task.isCancelled else { return (pair, current[pair]) }
                        return (pair, ArraySlice(mergeWordRuns(current[pair], current[pair + 1], bytes: frozenBytes, offsets: frozenOffsets, alias: sharedAlias)))
                    }
                }
                var parts: [(Int, ArraySlice<Int32>)] = []
                for await part in group { parts.append(part) }
                return parts.sorted { $0.0 < $1.0 }.map(\.1)
            }
        }
        let finalRefs = runs.first ?? []
        let wordCount = finalRefs.count
        guard !Task.isCancelled else { return .empty }
        BuildProfile.mark("search word merge (\(wordCount) unique)", since: mergeStart)
        let flattenStart = ContinuousClock.now

        // MARK: Flatten the merged run into the final table (+ byte-class masks + survivor ranks).
        // Two passes over contiguous partitions: byte counts first, then disjoint writes at
        // exact positions — masks are free since the pass reads every word byte anyway.
        let sharedSurvivorRank = DisjointBuffer(buffer: survivorRank)
        var wordBytes = [UInt8](repeating: 0, count: 0)
        var wordOffsets = [Int32](repeating: 0, count: wordCount + 1)
        var wordMasks = [UInt64](repeating: 0, count: wordCount)
        if wordCount > 0 {
            let partitions = min(workers, wordCount)
            let sliceSize = (wordCount + partitions - 1) / partitions
            let byteCounts = await withTaskGroup(of: (Int, Int).self) { group in
                for slice in stride(from: 0, to: wordCount, by: sliceSize) {
                    group.addTask {
                        var count = 0
                        frozenOffsets.withUnsafeBufferPointer { offsets in
                            for index in slice..<min(slice + sliceSize, wordCount) {
                                let ref = Int(finalRefs[index])
                                count += Int(offsets[ref + 1]) - Int(offsets[ref])
                            }
                        }
                        return (slice, count)
                    }
                }
                var parts: [(Int, Int)] = []
                for await part in group { parts.append(part) }
                return parts.sorted { $0.0 < $1.0 }
            }
            var byteCount = 0
            var bases: [Int: Int] = [:]
            bases.reserveCapacity(byteCounts.count)
            for (slice, count) in byteCounts {
                bases[slice] = byteCount
                byteCount += count
            }
            let sliceBases = bases
            wordBytes = [UInt8](repeating: 0, count: byteCount)
            guard !Task.isCancelled else { return .empty }
            // Disjoint writes into the shared arrays (each slice owns its byte range and its
            // rank positions): `concurrentPerform` stays inside the synchronous buffer scope,
            // so no pointer escapes — the same parallel primitive EPGGuide uses.
            let slices = stride(from: 0, to: wordCount, by: sliceSize).map { $0 }
            wordBytes.withUnsafeMutableBufferPointer { bytesOut in
                wordOffsets.withUnsafeMutableBufferPointer { offsetsOut in
                    wordMasks.withUnsafeMutableBufferPointer { masksOut in
                        let sharedBytes = DisjointBuffer(buffer: bytesOut)
                        let sharedOffsets = DisjointBuffer(buffer: offsetsOut)
                        let sharedMasks = DisjointBuffer(buffer: masksOut)
                        DispatchQueue.concurrentPerform(iterations: slices.count) { iteration in
                            let slice = slices[iteration]
                            let base = sliceBases[slice] ?? 0
                            frozenBytes.withUnsafeBufferPointer { bytes in
                                frozenOffsets.withUnsafeBufferPointer { offsets in
                                    var cursor = base
                                    let upper = min(slice + sliceSize, wordCount)
                                    for rank in slice..<upper {
                                        let ref = Int(finalRefs[rank])
                                        let w0 = Int(offsets[ref]), w1 = Int(offsets[ref + 1])
                                        var mask: UInt64 = 0
                                        if let target = sharedBytes.baseAddress {
                                            memcpy(target + cursor, bytes.baseAddress.unsafelyUnwrapped + w0, w1 - w0)
                                        }
                                        for position in w0..<w1 {
                                            mask |= UInt64(1) << (bytes[position] & 63)
                                        }
                                        cursor += w1 - w0
                                        sharedOffsets[rank] = Int32(cursor) - Int32(w1 - w0)
                                        sharedMasks[rank] = mask
                                        sharedSurvivorRank[ref] = Int32(rank + 1)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            wordOffsets[wordCount] = Int32(byteCount)
        }
        guard !Task.isCancelled else { return .empty }
        BuildProfile.mark("search flatten+masks", since: flattenStart)
        let remapStart = ContinuousClock.now

        // MARK: Per-chunk remap to ranks + posting-count histograms (parallel).
        // chunkHistograms is chunk-major raw memory: chunk c owns [c*wordCount, (c+1)*wordCount).
        // Every chunk position resolves its rank by chasing a handful of aliases (zero byte
        // comparisons), then the entry scan writes final ranks straight into the output array
        // (positions are known from entryWordOffsets) and counts every instance per rank.
        let histograms = UnsafeMutableBufferPointer<Int32>.allocate(capacity: max(chunkCount * wordCount, 1))
        defer { histograms.deallocate() }
        var entryWords = [Int32](repeating: 0, count: totalInstances)
        entryWords.withUnsafeMutableBufferPointer { entryWordsOut in
            let sharedEntryWords = DisjointBuffer(buffer: entryWordsOut)
            let sharedHistograms = DisjointBuffer(buffer: histograms)
            DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                let chunk = frozenChunks[chunkIndex]
                let histogramBase = chunkIndex * wordCount
                if wordCount > 0 {
                    for position in 0..<wordCount { sharedHistograms[histogramBase + position] = 0 }
                }
                let entries = chunk.wordCounts.count
                guard entries > 0 else { return }
                let wordsInChunk = frozenWordsInChunk[chunkIndex]
                var rankOfPosition = [Int32](repeating: 0, count: wordsInChunk)
                let wordBase = frozenWordBase[chunkIndex]
                for position in 0..<wordsInChunk {
                    var ref = wordBase + position
                    while sharedAlias[ref] != 0 { ref = Int(sharedAlias[ref]) - 1 }
                    rankOfPosition[position] = sharedSurvivorRank[ref] - 1
                }
                rankOfPosition.withUnsafeBufferPointer { ranks in
                    chunk.entryWords.withUnsafeBufferPointer { positions in
                        var local = 0
                        for entry in 0..<entries {
                            var out = Int(frozenEntryOffsets[chunk.start + entry])
                            let count = Int(chunk.wordCounts[entry])
                            for _ in 0..<count {
                                let rank = Int(ranks[Int(positions[local])])
                                local += 1
                                sharedEntryWords[out] = Int32(rank)
                                sharedHistograms[histogramBase + rank] += 1
                                out += 1
                            }
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled else { return .empty }
        BuildProfile.mark("search remap+histograms", since: remapStart)
        let inversionStart = ContinuousClock.now

        // MARK: Posting inversion (parallel counting sort).
        // Pass 1 turns the histograms into per-chunk bases relative to the rank start, emitting
        // per-rank totals; pass 2 scatters entries. Chunks own disjoint entry ranges and write
        // ascending entries within each rank — the exact output of the serial counting sort.
        // Pass 1 walks rank tiles of 256 with the chunk loop inside: every (chunk, tile) step
        // is a contiguous 1 KB run instead of a cache-line-strided column scan.
        var totals = [Int32](repeating: 0, count: wordCount)
        if wordCount > 0 {
            let tileSize = 256
            let tileCount = (wordCount + tileSize - 1) / tileSize
            totals.withUnsafeMutableBufferPointer { totalsOut in
                let sharedTotals = DisjointBuffer(buffer: totalsOut)
                let sharedHistograms = DisjointBuffer(buffer: histograms)
                DispatchQueue.concurrentPerform(iterations: tileCount) { tile in
                    let lower = tile * tileSize
                    let width = min(tileSize, wordCount - lower)
                    var running = [Int32](repeating: 0, count: width)
                    for chunk in 0..<chunkCount {
                        let base = chunk * wordCount + lower
                        for offset in 0..<width {
                            let cell = base + offset
                            let count = sharedHistograms[cell]
                            sharedHistograms[cell] = running[offset]
                            running[offset] += count
                        }
                    }
                    for offset in 0..<width {
                        sharedTotals[lower + offset] = running[offset]
                    }
                }
            }
        }
        var postingOffsets = [Int32](repeating: 0, count: wordCount + 1)
        totals.withUnsafeBufferPointer { counts in
            for rank in 0..<wordCount {
                postingOffsets[rank + 1] = postingOffsets[rank] + counts[rank]
            }
        }
        var postings = [Int32](repeating: 0, count: totalInstances)
        let frozenRanks = entryWords, frozenPostingOffsets = postingOffsets
        if totalInstances > 0 {
            postings.withUnsafeMutableBufferPointer { postingsOut in
                let sharedPostings = DisjointBuffer(buffer: postingsOut)
                let sharedHistograms = DisjointBuffer(buffer: histograms)
                DispatchQueue.concurrentPerform(iterations: chunkCount) { chunkIndex in
                    let chunk = frozenChunks[chunkIndex]
                    guard !chunk.wordCounts.isEmpty else { return }
                    let histogramBase = chunkIndex * wordCount
                    frozenRanks.withUnsafeBufferPointer { words in
                        frozenPostingOffsets.withUnsafeBufferPointer { offsets in
                            var position = Int(frozenEntryOffsets[chunk.start])
                            for entry in 0..<chunk.wordCounts.count {
                                let globalEntry = chunk.start + entry
                                let end = position + Int(chunk.wordCounts[entry])
                                while position < end {
                                    let rank = Int(words[position])
                                    let cell = histogramBase + rank
                                    sharedPostings[Int(offsets[rank]) + Int(sharedHistograms[cell])] = Int32(globalEntry)
                                    sharedHistograms[cell] += 1
                                    position += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        BuildProfile.mark("search postings inversion", since: inversionStart)

        return SearchIndex(
            channels: channels, movies: movies, series: series,
            baseScores: baseScores,
            nameBytes: nameBytes, nameOffsets: nameOffsets,
            entryWords: entryWords, entryWordOffsets: entryWordOffsets,
            wordBytes: wordBytes, wordOffsets: wordOffsets, wordMasks: wordMasks,
            postings: postings, postingOffsets: postingOffsets
        )
    }

    /// Stable merge of two runs of word positions, each sorted bytewise. Equal words keep the
    /// left copy (bytes are identical either way); the dropped reference records an alias to
    /// the survivor (+1 encoded) so the rank remap can chase it instead of searching. Output
    /// is sorted, unique — deterministic.
    private static func mergeWordRuns(
        _ left: ArraySlice<Int32>, _ right: ArraySlice<Int32>,
        bytes: [UInt8], offsets: [Int32], alias: DisjointBuffer<Int32>
    ) -> [Int32] {
        bytes.withUnsafeBufferPointer { bytes in
            offsets.withUnsafeBufferPointer { offsets in
                var result: [Int32] = []
                result.reserveCapacity(left.count + right.count)
                let left = left[...], right = right[...]
                var i = left.startIndex, j = right.startIndex
                while i < left.endIndex, j < right.endIndex {
                    let a = left[i], b = right[j]
                    let a0 = Int(offsets[Int(a)]), a1 = Int(offsets[Int(a) + 1])
                    let b0 = Int(offsets[Int(b)]), b1 = Int(offsets[Int(b) + 1])
                    let ordering = compareBytes(bytes, a0, a1 - a0, bytes, b0, b1 - b0)
                    if ordering < 0 {
                        result.append(a); i += 1
                    } else if ordering > 0 {
                        result.append(b); j += 1
                    } else {
                        result.append(a)
                        alias[Int(b)] = a &+ 1
                        i += 1; j += 1
                    }
                }
                result.append(contentsOf: left[i...])
                result.append(contentsOf: right[j...])
                return result
            }
        }
    }

    private static func processChunk(range: Range<Int>, describe: (Int) -> Source) -> Chunk {
        var chunk = Chunk(start: range.lowerBound)
        chunk.baseScores.reserveCapacity(range.count)
        chunk.nameLengths.reserveCapacity(range.count)
        chunk.wordCounts.reserveCapacity(range.count)
        chunk.entryWords.reserveCapacity(range.count * 3)
        var localIDs: [String: Int32] = Dictionary(minimumCapacity: range.count)
        var localWords: [String] = []
        var entry: [Int32] = []
        var wordBuffer: [UInt8] = []
        wordBuffer.reserveCapacity(32)
        func localID(_ word: String) -> Int32 {
            if let id = localIDs[word] { return id }
            let id = Int32(localWords.count)
            localIDs[word] = id
            localWords.append(word)
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

        // Finish the chunk with its unique words in bytewise order (the global table is then a
        // merge of sorted runs instead of a serial interning + sort), and entry words already
        // re-expressed as positions into that sorted table. Word order is total and elements
        // are unique, so the unstable sort cannot diverge from the serial semantics.
        let wordCount = localWords.count
        var idBytes: [UInt8] = []
        var idOffsets: [Int32] = [0]
        idOffsets.reserveCapacity(wordCount + 1)
        for word in localWords {
            idBytes.append(contentsOf: word.utf8)
            idOffsets.append(Int32(idBytes.count))
        }
        var order = (0..<Int32(wordCount)).map { $0 }
        idBytes.withUnsafeBufferPointer { bytes in
            idOffsets.withUnsafeBufferPointer { offsets in
                order.sort { a, b in
                    let a0 = Int(offsets[Int(a)]), a1 = Int(offsets[Int(a) + 1])
                    let b0 = Int(offsets[Int(b)]), b1 = Int(offsets[Int(b) + 1])
                    return compareBytes(bytes, a0, a1 - a0, bytes, b0, b1 - b0) < 0
                }
            }
        }
        var positionOfLocalID = [Int32](repeating: 0, count: wordCount)
        chunk.sortedWordBytes.reserveCapacity(idBytes.count)
        chunk.sortedWordOffsets.reserveCapacity(wordCount + 1)
        chunk.sortedWordOffsets.append(0)
        for (position, id) in order.enumerated() {
            positionOfLocalID[Int(id)] = Int32(position)
            chunk.sortedWordBytes.append(contentsOf: idBytes[Int(idOffsets[Int(id)])..<Int(idOffsets[Int(id) + 1])])
            chunk.sortedWordOffsets.append(Int32(chunk.sortedWordBytes.count))
        }
        positionOfLocalID.withUnsafeBufferPointer { map in
            chunk.entryWords.withUnsafeMutableBufferPointer { words in
                for index in words.indices {
                    words[index] = map[Int(words[index])]
                }
            }
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
