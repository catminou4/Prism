import Foundation
import PrismCore
import Testing
@testable import PrismData

@MainActor
@Suite("LibraryStore")
struct LibraryStoreTests {
    typealias F = Fixture

    @Test func watchlistMostRecentFirst() {
        let store = LibraryStore.inMemory()
        let a = TitleID(rawValue: "movie:a:"), b = TitleID(rawValue: "movie:b:")
        store.addToWatchlist(a)
        store.toggleWatchlist(b)
        #expect(store.watchlist == [b, a])
        store.addToWatchlist(a)
        #expect(store.watchlist == [a, b])
        store.toggleWatchlist(a)
        #expect(store.watchlist == [b])
        #expect(!store.isInWatchlist(a))
        store.removeFromWatchlist(b)
        #expect(store.watchlist.isEmpty)
    }

    @Test func dismissedTitlesLeaveTheWatchlistAndCanComeBack() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let store = LibraryStore(directories: directories, saveDelay: .milliseconds(10))
        let a = TitleID(rawValue: "movie:a:"), b = TitleID(rawValue: "movie:b:")
        store.addToWatchlist(a)
        store.dismiss(a)
        store.dismiss(b)
        store.dismiss(a)
        #expect(store.dismissed == [b, a], "most recent first, no duplicates")
        #expect(!store.isInWatchlist(a))
        #expect(store.isDismissed(b))
        store.flush()
        #expect(LibraryStore(directories: directories).dismissed == [b, a])
        store.undismiss(a)
        #expect(store.dismissed == [b])
        store.clearDismissed()
        #expect(store.dismissed.isEmpty)
    }

    @Test func favoritesToggleAndMove() {
        let store = LibraryStore.inMemory()
        for id in ["tf1", "france 2", "m6", "arte"] { store.toggleFavorite(id) }
        #expect(store.favoriteChannels == ["tf1", "france 2", "m6", "arte"])
        store.moveFavorites(fromOffsets: IndexSet(integer: 3), toOffset: 0)
        #expect(store.favoriteChannels == ["arte", "tf1", "france 2", "m6"])
        store.moveFavorites(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        #expect(store.favoriteChannels == ["france 2", "m6", "arte", "tf1"])
        store.toggleFavorite("m6")
        #expect(!store.isFavorite("m6"))
        #expect(store.favoriteChannels == ["france 2", "arte", "tf1"])
    }

    @Test func historyIsDedupedAndCapped() {
        let store = LibraryStore.inMemory()
        let content = ContentID(source: F.a, kind: .live, nativeID: "1")
        for index in 0..<250 { store.recordPlayback(target: .channel(groupID: "c\(index)"), contentID: content) }
        #expect(store.history.count == LibraryStore.maxHistory)
        #expect(store.history.first?.id == "c:c249")
        store.recordPlayback(target: .channel(groupID: "c100"), contentID: content)
        #expect(store.history.first?.id == "c:c100")
        #expect(store.history.count == LibraryStore.maxHistory)
        #expect(Set(store.history.map(\.id)).count == store.history.count)
        store.clearHistory()
        #expect(store.history.isEmpty)
    }

    @Test func watchedState() {
        let store = LibraryStore.inMemory()
        let id = ContentID(source: F.a, kind: .movie, nativeID: "1")
        let title = TitleID(rawValue: "movie:x:")
        store.updateProgress(PlaybackProgress(contentID: id, titleID: title, position: 600, duration: 6_000))
        #expect(!store.isWatched(id))
        #expect(store.progress(for: id)?.position == 600)
        store.markWatched(id, titleID: nil)
        #expect(store.isWatched(id))
        #expect(store.progress(for: id)?.isFinished == true)
        #expect(store.progress(for: id)?.titleID == title)
        store.markUnwatched(id)
        #expect(!store.isWatched(id))
        #expect(store.progress(for: id) == nil)
        store.updateProgress(PlaybackProgress(contentID: id, position: 5_990, duration: 6_000))
        #expect(store.isWatched(id), "finishing playback marks as watched")
        store.clearProgress(for: id)
        #expect(store.progress(for: id) == nil)
    }

    @Test func shortDemoEpisodeCanResumeBeforeTheEnd() async throws {
        let catalog = await CatalogBuilder.build(sources: DemoContent.makeSources(), catalogs: DemoContent.makeCatalogs())
        let title = try #require(catalog.series.first)
        let episode = try #require(title.variants.first?.series?.seasons?.first?.episodes.first)
        let duration = TimeInterval(try #require(episode.durationSeconds))
        let store = LibraryStore.inMemory()

        store.updateProgress(PlaybackProgress(contentID: episode.id, titleID: title.id, position: 12, duration: duration))
        #expect(!store.isWatched(episode.id))
        #expect(store.continueWatching(in: catalog).first?.progress?.position == 12)

        store.updateProgress(PlaybackProgress(contentID: episode.id, titleID: title.id, position: duration - 1, duration: duration))
        #expect(store.isWatched(episode.id))
    }

    @Test func persistenceWithDebounceAndFlush() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let store = LibraryStore(directories: directories, saveDelay: .milliseconds(150))
        let movie = ContentID(source: F.a, kind: .movie, nativeID: "1")
        let title = TitleID(rawValue: "movie:heat:1995")
        store.updateProgress(PlaybackProgress(contentID: movie, titleID: title, position: 100, duration: 1_000, updatedAt: F.reference))
        store.addToWatchlist(title)
        store.toggleFavorite("tf1")
        store.setPreferredVariant(movie, for: title)
        store.setPreferredChannelVariant(ContentID(source: F.a, kind: .live, nativeID: "1"), for: "tf1")
        store.lastChannelGroupID = "tf1"
        store.recordPlayback(target: .title(title), contentID: movie)
        #expect(store.saveCount == 0, "writes are debounced")
        #expect(!FileManager.default.fileExists(atPath: directories.libraryFile.path(percentEncoded: false)))

        try await Task.sleep(for: .milliseconds(600))
        #expect(store.saveCount == 1, "a burst of mutations produces a single write")

        let reloaded = LibraryStore(directories: directories)
        #expect(reloaded.progress(for: movie)?.position == 100)
        #expect(reloaded.watchlist == [title])
        #expect(reloaded.favoriteChannels == ["tf1"])
        #expect(reloaded.preferredVariant(for: title) == movie)
        #expect(reloaded.preferredChannelVariant(for: "tf1")?.nativeID == "1")
        #expect(reloaded.lastChannelGroupID == "tf1")
        #expect(reloaded.history.first?.target == .title(title))

        store.updateProgress(PlaybackProgress(contentID: movie, titleID: title, position: 200, duration: 1_000))
        store.flush()
        #expect(store.saveCount == 2)
        #expect(LibraryStore(directories: directories).progress(for: movie)?.position == 200)
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.saveCount == 2, "flush cancels the pending debounced write")
    }

    @Test func corruptLibraryFileStartsEmpty() throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        try Data("{\"watchlist\": 12}".utf8).write(to: directories.libraryFile)
        let store = LibraryStore(directories: directories)
        #expect(store.watchlist.isEmpty)
        try Data("not json".utf8).write(to: directories.libraryFile)
        #expect(LibraryStore(directories: directories).progress.isEmpty)
    }

    @Test func continueWatchingOrderingAndNextEpisode() async throws {
        let seasons = F.seasons(series: "dark", source: F.a, counts: [2, 2])
        let catalogs = [SourceCatalog(
            sourceID: F.a,
            movies: [F.movie(F.a, "heat", "Heat", year: 1995), F.movie(F.a, "alien", "Alien", year: 1979), F.movie(F.a, "dune", "Dune", year: 2021)],
            series: [
                F.series(F.a, "dark", "Dark", year: 2017, seasons: seasons),
                F.series(F.a, "bear", "The Bear", year: 2022, seasons: F.seasons(series: "bear", source: F.a, counts: [3])),
                F.series(F.a, "xt", "Xtream Show", year: 2020),
                F.series(F.a, "done", "Done", year: 2010, seasons: F.seasons(series: "done", source: F.a, counts: [1])),
                F.series(F.a, "opened", "Opened", year: 2011, seasons: F.seasons(series: "opened", source: F.a, counts: [1])),
            ]
        )]
        let catalog = await F.build([F.source(F.a)], catalogs)
        let store = LibraryStore.inMemory()
        func titleID(_ kind: MediaKind, _ id: String) -> TitleID {
            catalog.titleID(containing: ContentID(source: F.a, kind: kind, nativeID: id))!
        }
        let t0 = F.reference
        // Movie in progress (oldest).
        store.updateProgress(PlaybackProgress(contentID: ContentID(source: F.a, kind: .movie, nativeID: "heat"), titleID: titleID(.movie, "heat"), position: 1_200, duration: 6_000, updatedAt: t0))
        // Finished movie: excluded.
        store.updateProgress(PlaybackProgress(contentID: ContentID(source: F.a, kind: .movie, nativeID: "alien"), titleID: titleID(.movie, "alien"), position: 6_000, duration: 6_000, updatedAt: t0.addingTimeInterval(50)))
        // Barely started movie: excluded.
        store.updateProgress(PlaybackProgress(contentID: ContentID(source: F.a, kind: .movie, nativeID: "dune"), titleID: titleID(.movie, "dune"), position: 2, duration: 6_000, updatedAt: t0.addingTimeInterval(60)))
        // Dark: S1E2 finished → next is S2E1 (crosses seasons).
        let darkS1E1 = seasons[0].episodes[0].id, darkS1E2 = seasons[0].episodes[1].id
        store.updateProgress(PlaybackProgress(contentID: darkS1E1, titleID: titleID(.series, "dark"), position: 2_400, duration: 2_400, updatedAt: t0.addingTimeInterval(10)))
        store.updateProgress(PlaybackProgress(contentID: darkS1E2, titleID: titleID(.series, "dark"), position: 2_390, duration: 2_400, updatedAt: t0.addingTimeInterval(40)))
        // The Bear: E2 in progress → resume.
        let bearE2 = ContentID(source: F.a, kind: .episode, nativeID: "bear-s1e2")
        store.updateProgress(PlaybackProgress(contentID: bearE2, titleID: titleID(.series, "bear"), position: 300, duration: 1_800, updatedAt: t0.addingTimeInterval(30)))
        // Xtream series without known seasons, last episode finished → resume fallback.
        let xtEpisode = ContentID(source: F.a, kind: .episode, nativeID: "991")
        store.updateProgress(PlaybackProgress(contentID: xtEpisode, titleID: titleID(.series, "xt"), position: 1_800, duration: 1_800, updatedAt: t0.addingTimeInterval(20)))
        // Completed series: last episode finished, nothing next → excluded.
        store.updateProgress(PlaybackProgress(contentID: ContentID(source: F.a, kind: .episode, nativeID: "done-s1e1"), titleID: titleID(.series, "done"), position: 2_400, duration: 2_400, updatedAt: t0.addingTimeInterval(70)))
        // Opened from history without progress → start series.
        store.recordPlayback(target: .title(titleID(.series, "opened")), contentID: ContentID(source: F.a, kind: .episode, nativeID: "opened-s1e1"))

        let items = store.continueWatching(in: catalog)
        #expect(items.map(\.title.title) == ["Opened", "Dark", "The Bear", "Xtream Show", "Heat"])
        let opened = items[0]
        #expect(opened.kind == .startSeries)
        let dark = items[1]
        #expect(dark.kind == .nextEpisode)
        #expect(dark.episode?.season == 2 && dark.episode?.number == 1)
        #expect(dark.contentID == seasons[1].episodes[0].id)
        #expect(dark.progress == nil)
        let bear = items[2]
        #expect(bear.kind == .resume)
        #expect(bear.episode?.number == 2)
        #expect(bear.progress?.position == 300)
        #expect(items[3].kind == .resume && items[3].episode == nil)
        #expect(items[4].kind == .resume && items[4].contentID.nativeID == "heat")
        #expect(store.continueWatching(in: catalog, limit: 2).count == 2)
        #expect(store.continueWatching(in: .empty).isEmpty)
    }
}
