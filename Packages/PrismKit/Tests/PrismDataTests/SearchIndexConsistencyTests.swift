import Foundation
import PrismCore
import Testing
@testable import PrismData

/// The parallel `SearchIndex.build` must produce byte-identical tables across repetitions and
/// a word table in exactly the bytewise order the serial implementation produced: length-first
/// lexicographic ordering of the raw bytes is NOT the contract — `compareBytes` compares
/// lexicographically and uses length only as the tie-breaker.
struct SearchIndexConsistencyTests {
    typealias F = Fixture

    static func makeCatalog() async -> Catalog {
        var random = CatalogIndexConsistencyTests.Random(state: 99)
        let (sources, catalogs) = CatalogIndexConsistencyTests.generated(random: &random)
        return await F.build(sources, catalogs)
    }

    @Test func buildIsByteIdenticalAcrossRepetitions() async {
        let catalog = await Self.makeCatalog()
        let first = await SearchIndex.build(from: catalog)
        let second = await SearchIndex.build(from: catalog)
        #expect(first.wordBytes == second.wordBytes)
        #expect(first.wordOffsets == second.wordOffsets)
        #expect(first.wordMasks == second.wordMasks)
        #expect(first.postings == second.postings)
        #expect(first.postingOffsets == second.postingOffsets)
        #expect(first.entryWords == second.entryWords)
        #expect(first.entryWordOffsets == second.entryWordOffsets)
        #expect(first.nameBytes == second.nameBytes)
        #expect(first.nameOffsets == second.nameOffsets)
        #expect(first.baseScores == second.baseScores)
        #expect(first.entryCount > 8_192)
    }

    @Test func wordTableIsInBytewiseLexicographicOrder() async {
        let catalog = await Self.makeCatalog()
        let index = await SearchIndex.build(from: catalog)
        guard index.wordCount > 1 else { return }
        // For every adjacent pair: lexicographic byte order, length only as tie-breaker,
        // and strict ordering (no duplicate words).
        var violations = 0
        for rank in 0..<(index.wordCount - 1) {
            let a0 = Int(index.wordOffsets[rank]), a1 = Int(index.wordOffsets[rank + 1])
            let b0 = Int(index.wordOffsets[rank + 1]), b1 = Int(index.wordOffsets[rank + 2])
            let a = Array(index.wordBytes[a0..<a1])
            let b = Array(index.wordBytes[b0..<b1])
            let common = min(a.count, b.count)
            var ordering: Int? = nil
            for position in 0..<common where a[position] != b[position] {
                ordering = a[position] < b[position] ? -1 : 1
                break
            }
            if ordering == nil { ordering = a.count == b.count ? 0 : (a.count < b.count ? -1 : 1) }
            if ordering != -1 { violations += 1 }
        }
        #expect(violations == 0)
    }

    @Test func postingListsMatchEntryWordsExactly() async {
        let catalog = await Self.makeCatalog()
        let index = await SearchIndex.build(from: catalog)
        // Reconstruct every posting list from entryWords and compare against the built lists.
        var expected: [Int: [Int]] = [:]
        for entry in 0..<index.entryCount {
            let start = Int(index.entryWordOffsets[entry]), end = Int(index.entryWordOffsets[entry + 1])
            for position in start..<end {
                expected[Int(index.entryWords[position]), default: []].append(entry)
            }
        }
        var checked = 0
        for rank in 0..<index.wordCount {
            let start = Int(index.postingOffsets[rank]), end = Int(index.postingOffsets[rank + 1])
            let built = Array(index.postings[start..<end]).map(Int.init)
            let want = expected[rank] ?? []
            #expect(built == want)
            // Entries ascend within each posting list (channel < movie < series concat order).
            #expect(built == built.sorted())
            checked += 1
        }
        #expect(checked == index.wordCount)
        // Every entry word must be a valid rank and consistent with the name encoding.
        for position in index.entryWords {
            #expect(position >= 0 && Int(position) < index.wordCount)
        }
    }

    @Test func parallelInterningMatchesSerialValues() async {
        var random = CatalogIndexConsistencyTests.Random(state: 5)
        let (_, catalogs) = CatalogIndexConsistencyTests.generated(random: &random)
        var catalog = catalogs[0]
        var serial = catalog
        serial.shareRepeatedValues()
        catalog.shareRepeatedValuesParallel()
        #expect(catalog.channels == serial.channels)
        #expect(catalog.movies == serial.movies)
        #expect(catalog.series == serial.series)
        // Deterministic across repetitions.
        var again = catalogs[0]
        again.shareRepeatedValuesParallel()
        #expect(again.channels == catalog.channels)
        #expect(again.movies == catalog.movies)
    }
}
