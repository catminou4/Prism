import Foundation
import Testing
import PrismCore
@testable import PrismUI
@testable import PrismData

/// ZZAudit — offscreen measurements for the detail-page performance audit.
/// Prints timings; assertions are sanity checks only.
@Suite("ZZAudit detail perf", .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditDetailBench {

    /// Cost of rebuilding `editions` ([TitleEdition]) the way TitleDetailView.body does:
    /// one PlaybackEdition(tags:categoryLanguages:) per variant, per body evaluation.
    @Test func editionRebuildCost() {
        let source = Source(name: "Source A", kind: .xtream, serverURL: URL(string: "https://x.test"), username: "u")
        var variants: [MediaVariant] = []
        for i in 0..<60 {
            variants.append(.series(Series(
                sourceID: source.id, nativeID: "s\(i)", title: "Serie \(i)",
                quality: .uhd, tags: ["VF", "FR", "4K", "MULTI"]
            )))
        }
        let clock = ContinuousClock()
        // Warmup
        for _ in 0..<50 {
        _ = variants.map { TitleEdition(variant: $0, source: source, categoryLanguages: ["fr", "en"]) }
        }
        let iterations = 200
        let start = clock.now
        var sink = 0
        for _ in 0..<iterations {
            let editions = variants.map { TitleEdition(variant: $0, source: source, categoryLanguages: ["fr", "en"]) }
            sink += editions.count
        }
        let elapsed = start.duration(to: clock.now)
        let perEval = Double(elapsed.components.seconds) * 1e9 / Double(iterations) / 1e3 // µs? -> ms below
        print("ZZAUDIT editions(60 variants): \(elapsed) total / \(iterations) = \(perEval) µs per rebuild")
        #expect(sink == iterations * 60)
    }

    /// Worst-case `heroEpisode`/`nextEpisode` scan: 2000 episodes, all watched → full scan.
    @Test func episodeScanCost() async {
        let source = Source(name: "Source A", kind: .xtream, serverURL: URL(string: "https://x.test"), username: "u")
        let seriesID = ContentID(source: source.id, kind: .series, nativeID: "big")
        var episodes: [Episode] = []
        episodes.reserveCapacity(2000)
        for e in 1...2000 {
            episodes.append(Episode(
                seriesID: seriesID, sourceID: source.id, nativeID: "e\(e)",
                season: 1, number: e, title: "E\(e)",
                streamURL: URL(string: "https://x.test/e\(e).m3u8")!
            ))
        }
        let detail = SeriesDetail(seriesID: seriesID, seasons: [Season(number: 1, episodes: episodes)])
        let edition = TitleEdition(variant: .series(Series(sourceID: source.id, nativeID: "big", title: "Big")), source: source)
        let inventory = await DetailEpisodeInventory.build(edition: edition, detail: detail)
        #expect(inventory.orderedEpisodes.count == 2000)

        // All episodes watched: nextEpisode must scan the whole list twice (season>0 pass, then any).
        var watched: Set<ContentID> = []
        var progress: [ContentID: PlaybackProgress] = [:]
        for ep in inventory.orderedEpisodes {
            watched.insert(ep.id)
            let dur = 2_400.0
            progress[ep.id] = PlaybackProgress(contentID: ep.id, position: dur, duration: dur)
        }
        let clock = ContinuousClock()
        let iterations = 300
        var sink: Episode?
        let start = clock.now
        for _ in 0..<iterations {
            sink = inventory.nextEpisode(after: nil, isWatched: { watched.contains($0) || progress[$0]?.isFinished == true })
        }
        let scanElapsed = start.duration(to: clock.now)
        print("ZZAUDIT nextEpisode(2000 eps, all watched): \(scanElapsed) / \(iterations)")
        #expect(sink != nil)

        // latestProgress fallback path (progress.count >= episodes.count → scans orderedEpisodes).
        let start2 = clock.now
        var latest: PlaybackProgress?
        for _ in 0..<iterations {
            latest = inventory.latestProgress(in: progress)
        }
        let latestElapsed = start2.duration(to: clock.now)
        print("ZZAUDIT latestProgress(2000 eps): \(latestElapsed) / \(iterations)")
        #expect(latest != nil)
    }

    /// `LibraryStore.isInWatchlist` linear scan cost at the 2000-entry cap.
    @Test func watchlistScanCost() {
        let store = LibraryStore.inMemory()
        // Fill to cap via repeated adds (maxWatchlist = 2000).
        for i in 0..<2_000 {
            store.addToWatchlist(TitleID(kind: .movie, normalizedTitle: "t\(i)", year: nil))
        }
        // "t0" sits at the tail of the array (oldest insert order reversed);
        // "absent" forces a full 2000-element scan miss.
        let tail = TitleID(kind: .movie, normalizedTitle: "t0", year: nil)
        let absent = TitleID(kind: .movie, normalizedTitle: "zzz_absent", year: nil)
        let clock = ContinuousClock()
        let iterations = 5_000
        var hits = 0
        let start = clock.now
        for _ in 0..<iterations {
            if store.isInWatchlist(tail) { hits += 1 }
            _ = store.isInWatchlist(absent)
        }
        let elapsed = start.duration(to: clock.now)
        print("ZZAUDIT isInWatchlist(2000 entries): \(elapsed) / \(iterations*2) calls (hit+miss), hits=\(hits)")
        #expect(hits == iterations)
    }

    /// `QuickPlay.option` on a 60-variant film — the hero re-evaluates it per page eval.
    /// `rank` used to rebuild a tag Set per sort comparison; it is now scored once per variant.
    @MainActor @Test func quickPlayOptionCost() async throws {
        let app = await AppModel.preview()
        let source = try #require(app.sources.first)
        let stream = try #require(URL(string: "https://example.invalid/bench.mp4"))
        var variants: [MediaVariant] = []
        variants.reserveCapacity(60)
        for i in 0..<60 {
            variants.append(.movie(Movie(
                sourceID: source.id, nativeID: "bench\(i)", title: "Film \(i)",
                streamURL: stream, quality: .uhd, tags: ["VF", "FR", "4K", "MULTI"]
            )))
        }
        let title = MediaTitle(
            id: TitleID(rawValue: "bench:film"), kind: .movie, title: "Film", year: nil, variants: variants
        )
        for _ in 0..<20 { _ = QuickPlay.option(for: title, app: app) }
        let clock = ContinuousClock()
        let iterations = 300
        var hits = 0
        let start = clock.now
        for _ in 0..<iterations {
            if QuickPlay.option(for: title, app: app) != nil { hits += 1 }
        }
        let elapsed = start.duration(to: clock.now)
        print("ZZAUDIT quickPlay.option(60 variants): \(elapsed) / \(iterations)")
        #expect(hits == iterations)

        // Replica of the previous comparator — `rank` rebuilt a tag Set per comparison.
        let frenchTags: Set<String> = ["FR", "FRA", "FRENCH", "VF", "VFF", "VFQ", "VFI", "TRUEFRENCH", "MULTI"]
        let englishTags: Set<String> = ["EN", "ENG", "ENGLISH", "VO", "VOSTFR", "MULTI"]
        func oldRank(_ variant: MediaVariant) -> Int {
            let tags = Set(variant.tags.map { $0.uppercased() })
            var score = variant.quality.rawValue
            if !tags.isDisjoint(with: frenchTags) { score += 20 }
            if !tags.isDisjoint(with: englishTags) { score += 20 }
            return score
        }
        for _ in 0..<10 { _ = variants.sorted { oldRank($0) != oldRank($1) ? oldRank($0) > oldRank($1) : $0.quality > $1.quality } }
        let oldStart = clock.now
        for _ in 0..<iterations {
            _ = variants.sorted { lhs, rhs in
                let left = oldRank(lhs), right = oldRank(rhs)
                return left != right ? left > right : lhs.quality > rhs.quality
            }
        }
        print("ZZAUDIT quickPlay rank-per-comparison sort(60 variants): \(oldStart.duration(to: clock.now)) / \(iterations)")

        // The shipped path: score once per variant, then sort.
        for _ in 0..<10 {
            _ = variants.map { (score: oldRank($0), variant: $0) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.variant.quality > $1.variant.quality }
                .map { $0.variant }
        }
        let newStart = clock.now
        for _ in 0..<iterations {
            _ = variants.map { (score: oldRank($0), variant: $0) }
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.variant.quality > $1.variant.quality }
                .map { $0.variant }
        }
        print("ZZAUDIT quickPlay score-once sort(60 variants): \(newStart.duration(to: clock.now)) / \(iterations)")
    }
}
