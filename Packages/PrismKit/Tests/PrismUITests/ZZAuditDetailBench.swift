import Foundation
import Testing
import PrismCore
@testable import PrismUI
@testable import PrismData

/// ZZAudit — offscreen measurements for the detail-page performance audit.
/// Prints timings; assertions are sanity checks only.
@Suite("ZZAudit detail perf")
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
}
