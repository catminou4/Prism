import Foundation
import PrismCore
import PrismData
import Testing
@testable import PrismUI

/// Gated probe for the invalidation-surface pass: measures what a `catalog`
/// publish and a `CurationRequest` evaluation cost on the main actor with a
/// maximally populated library, and pins the `refreshFeed` freshness invariant
/// (a request built while the profile memo is dirty must stay current).
/// Run in Debug or Release with PRISM_UIINV_BENCH=1.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_UIINV_BENCH"] == "1"))
struct ZZUIInvBench {
    private func ms(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        body()
        return Double(start.duration(to: clock.now).components.seconds) * 1_000
            + Double(start.duration(to: clock.now).components.attoseconds) / 1e15
    }

    private func populate(_ library: LibraryStore) {
        for i in 0..<2_000 { library.dismiss(TitleID(rawValue: "dismissed:\(i)")) }
        for i in 0..<2_000 { library.addToWatchlist(TitleID(rawValue: "watch:\(i)")) }
        for i in 0..<3_000 {
            library.updateProgress(PlaybackProgress(
                contentID: ContentID(rawValue: "progress:\(i)"),
                titleID: TitleID(rawValue: "pt:\(i)"), position: 10, duration: 100))
        }
        for i in 0..<5_000 {
            library.setPreferredVariant(ContentID(rawValue: "pref:\(i)"), for: TitleID(rawValue: "pref-t:\(i)"))
        }
        for i in 0..<200 {
            library.recordPlayback(target: .title(TitleID(rawValue: "hist:\(i)")), contentID: ContentID(rawValue: "hc:\(i)"))
        }
    }

    @Test func publishAndRequestCosts() async throws {
        let app = await AppModel.preview()
        populate(app.library)
        print("[uiinv] library: dismissed=\(app.library.dismissed.count) watchlist=\(app.library.watchlist.count) "
            + "progress=\(app.library.progress.count) preferred=\(app.library.preferredVariants.count) "
            + "history=\(app.library.history.count)")

        // Prime the profile cache, then measure steady-state reads.
        _ = app.curationProfile
        var profileSamples: [Double] = []
        for _ in 0..<50 { profileSamples.append(ms { _ = app.curationProfile }) }
        print("[uiinv] curationProfile cached per call: min \(String(format: "%.4f", profileSamples.min()!)) ms, "
            + "median \(String(format: "%.4f", profileSamples.sorted()[25])) ms")

        var requestSamples: [Double] = []
        for _ in 0..<50 { requestSamples.append(ms { _ = app.curationRequest(for: .home) }) }
        print("[uiinv] curationRequest per call: min \(String(format: "%.4f", requestSamples.min()!)) ms, "
            + "median \(String(format: "%.4f", requestSamples.sorted()[25])) ms")

        let a = app.curationRequest(for: .home)
        let b = app.curationRequest(for: .home)
        var eqSamples: [Double] = []
        for _ in 0..<50 { eqSamples.append(ms { _ = (a == b) }) }
        print("[uiinv] CurationRequest == : min \(String(format: "%.4f", eqSamples.min()!)) ms, "
            + "median \(String(format: "%.4f", eqSamples.sorted()[25])) ms")

        // Invalidation: a real library mutation must drop the cache and bump the
        // revision exactly once per content change.
        let revBefore = app.curationProfileRevision
        app.library.addToWatchlist(TitleID(rawValue: "watch:999999"))
        // willSet already dropped the memo synchronously; the rebuild is lazy.
        _ = app.curationProfile
        let revAfter = app.curationProfileRevision
        print("[uiinv] revision bump on real mutation: \(revBefore) -> \(revAfter) (expect +1)")
        #expect(revAfter == revBefore + 1)

        // No-op mutation (same content rewritten) must not bump the revision.
        let revStable = app.curationProfileRevision
        app.library.addToWatchlist(TitleID(rawValue: "watch:999999"))
        _ = app.curationProfile
        #expect(app.curationProfileRevision == revStable)

        // A second mutation while dirty coalesces into one rebuild.
        app.library.dismiss(TitleID(rawValue: "dismissed:extra"))
        app.library.recordPlayback(target: .title(TitleID(rawValue: "hist:extra")), contentID: ContentID(rawValue: "hc:extra"))
        _ = app.curationProfile
        #expect(app.curationProfileRevision == revStable + 1)

        // Steady state again after invalidation.
        var postSamples: [Double] = []
        for _ in 0..<50 { postSamples.append(ms { _ = app.curationRequest(for: .home) }) }
        print("[uiinv] curationRequest after invalidation: median \(String(format: "%.4f", postSamples.sorted()[25])) ms")

        // Deferred reconcile: give it real work — a preferred variant recorded
        // under a wrong title id must be remapped onto the catalog's canonical
        // id once the deferred task runs.
        guard let title = app.catalog.movies.first, let variant = title.variants.first else {
            Issue.record("preview catalog has no movie variants")
            return
        }
        let wrongTitle = TitleID(rawValue: "wrong:\(title.id.rawValue)")
        app.library.setPreferredVariant(variant.id, for: wrongTitle)
        #expect(app.library.preferredVariant(for: title.id) == nil)
        let clock = ContinuousClock()
        let start = clock.now
        await app.rebuild()
        let elapsed = start.duration(to: clock.now)
        let publishMs = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1e15
        // Poll until the deferred utility task lands (bounded).
        var reconciled = false
        for _ in 0..<40 where !reconciled {
            try? await Task.sleep(for: .milliseconds(25))
            reconciled = app.library.preferredVariant(for: title.id) == variant.id
        }
        print("[uiinv] rebuild() publish-side: \(String(format: "%.1f", publishMs)) ms; "
            + "deferred reconcile landed: \(reconciled)")
        #expect(reconciled)
    }

    /// Reproduces HomePreferencesTests.curatedFeedsAreIsolatedPerScope's first
    /// refreshFeed rejection: dumps every CurationRequest field before/after.
    @Test func refreshFeedRepro() async throws {
        let model = await AppModel.preview()
        let request = model.curationRequest(for: .home)
        let fresh = model.curationRequest(for: .home)
        let eq = request == fresh
        let catPair = "\(request.catalogRevision)/\(fresh.catalogRevision)"
        let curPair = "\(request.curationRevision)/\(fresh.curationRevision)"
        let trendPair = "\(request.trendingRevision)/\(fresh.trendingRevision)"
        let profPair = "\(request.profileRevision)/\(fresh.profileRevision)"
        let langPair = "\(request.languages.count)/\(fresh.languages.count)"
        print("[uiinv-repro] equal=\(eq) cat=\(catPair) cur=\(curPair) trend=\(trendPair) "
            + "profRev=\(profPair) lang=\(langPair) day=\(request.day) isBuilt=\(model.curationIndex.isBuilt)")
        await model.refreshFeed(request)
        print("[uiinv-repro] hasFeed(home)=\(model.hasFeed(for: .home)) "
            + "shelves=\(model.feed(for: .home).shelves.map(\.id))")
        #expect(model.hasFeed(for: .home))
    }
}
