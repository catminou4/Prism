import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Coverage for the bounded caches, cheap archive-header reads, disk hygiene and the
/// in-flight deduplication added for the 120 Hz fluidity pass.
struct BoundedCachesTests {
    typealias F = Fixture

    @Test func boundedCacheEvictsOldestAndRefreshesOrder() {
        var cache = BoundedCache<String, Int>(limit: 3)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        #expect(cache.count == 3)
        #expect(cache.value(for: "a") == 1) // read marks "a" as recent: "b" is now the oldest
        cache.insert(4, for: "d")
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "d") == 4)
        #expect(cache.count == 3)
        // Reads refreshed "a" and "d"; "c" is now the least recently used entry.
        cache.insert(5, for: "e")
        #expect(cache.value(for: "c") == nil, "inserting past the limit evicts the least recently used")
        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "e") == 5)
        #expect(cache.count == 3)
    }

    @Test func boundedCacheReinsertRefreshesRecencyWithoutEviction() {
        var cache = BoundedCache<String, Int>(limit: 3)
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")
        cache.insert(3, for: "c")
        // Reinserting an existing key must behave like a read: the value is replaced,
        // the key becomes most-recently-used, and nothing is evicted or duplicated.
        cache.insert(30, for: "a")
        #expect(cache.count == 3)
        #expect(cache.value(for: "a") == 30)
        cache.insert(4, for: "d")
        #expect(cache.value(for: "b") == nil, "\"b\" is now the least recently used entry")
        #expect(cache.value(for: "a") == 30)
        #expect(cache.value(for: "c") == 3)
        #expect(cache.value(for: "d") == 4)
        #expect(cache.count == 3)
    }

    @Test func epgFetchedAtReadsTheArchiveHeaderOnly() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let cache = EPGCache(directories: directories, version: EPGCache.formatVersion)
        #expect(await cache.fetchedAt(F.a) == nil)
        let programs = [F.program("tf1.fr", 0, 30, "Journal")]
        try await cache.save(.init(programs: programs, fetchedAt: F.reference), for: F.a)
        #expect(await cache.fetchedAt(F.a) == F.reference)
        #expect(await cache.fetchedAt(F.b) == nil, "another source id never matches the header")
    }

    @Test func obsoleteArchiveVersionsArePurged() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let directory = directories.caches.appending(path: "Catalogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let catalog = SourceCatalog(sourceID: F.a, fetchedAt: F.reference)
        let current = try await CatalogCache.encode(catalog, version: CatalogCache.formatVersion)
        let foreign = try await CatalogCache.encode(catalog, version: CatalogCache.formatVersion + 1)
        let urls = ["good.catalog", "old.catalog", "junk.catalog", "note.txt"]
        for (name, data) in zip(urls, [current, foreign, Data("junk".utf8), Data("keep".utf8)]) {
            try data.write(to: directory.appending(path: name))
        }
        try FileManager.default.createDirectory(at: directory.appending(path: "dir.catalog"), withIntermediateDirectories: true)

        await Task.detached(priority: .utility) {
            SegmentedArchive.purgeObsoleteFiles(in: directory, version: CatalogCache.formatVersion, suffix: "catalog")
        }.value

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "good.catalog").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "old.catalog").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "junk.catalog").path))
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "note.txt").path), "other suffixes are untouched")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "dir.catalog").path), "directories are untouched")
    }

    @MainActor
    @Test func loadedLibraryCollectionsAreCapped() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        var file = LibraryFile(
            watchlist: [], favoriteChannels: [], progress: [], watched: [], history: [],
            preferredVariants: [], preferredChannelVariants: [], lastChannelGroupID: nil, dismissed: []
        )
        file.watchlist = (0..<(LibraryStore.maxWatchlist + 25)).map { TitleID(rawValue: "movie:w\($0):") }
        file.favoriteChannels = (0..<(LibraryStore.maxFavoriteChannels + 5)).map { "group-\($0)" }
        file.watched = (0..<(LibraryStore.maxWatched + 10)).map {
            ContentID(source: F.a, kind: .movie, nativeID: "w\($0)")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: directories.libraryFile)

        let store = LibraryStore(directories: directories)
        await store.awaitDiskLoad()
        #expect(store.watchlist.count == LibraryStore.maxWatchlist)
        #expect(store.favoriteChannels.count == LibraryStore.maxFavoriteChannels)
        #expect(store.watched.count == LibraryStore.maxWatched)
    }

    @MainActor
    @Test func loadedLibraryCollectionsKeepDeterministicSubsets() async throws {
        // `apply(_:)` caps every collection: arrays keep their file-order prefix,
        // watched keeps the entries with the freshest progress then smallest ids.
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        var file = LibraryFile(
            watchlist: [], favoriteChannels: [], progress: [], watched: [], history: [],
            preferredVariants: [], preferredChannelVariants: [], lastChannelGroupID: nil, dismissed: []
        )
        file.watchlist = (0..<(LibraryStore.maxWatchlist + 7)).map { TitleID(rawValue: "movie:w\($0)") }
        file.dismissed = (0..<(LibraryStore.maxDismissed + 3)).map { TitleID(rawValue: "movie:d\($0)") }
        file.favoriteChannels = (0..<(LibraryStore.maxFavoriteChannels + 4)).map { "ch\($0)" }
        file.history = (0..<(LibraryStore.maxHistory + 6)).map {
            HistoryEntry(target: .title(TitleID(rawValue: "movie:h\($0)")), lastContentID: ContentID(source: F.a, kind: .movie, nativeID: "h\($0)"), watchedAt: F.reference)
        }
        file.preferredVariants = (0..<(LibraryStore.maxPreferredEntries + 2)).map {
            .init(key: "k\($0)", contentID: ContentID(source: F.a, kind: .movie, nativeID: "p\($0)"))
        }
        file.preferredChannelVariants = (0..<(LibraryStore.maxPreferredEntries + 2)).map {
            .init(key: "g\($0)", contentID: ContentID(source: F.a, kind: .live, nativeID: "q\($0)"))
        }

        // Watched pruning is progress-aware: the five lexicographically largest ids would be
        // dropped by a plain rawValue cut, but fresh progress must keep them.
        let allWatched = (0..<(LibraryStore.maxWatched + 10)).map { ContentID(source: F.a, kind: .movie, nativeID: "w\($0)") }
        let progressed = Set(allWatched.sorted { $0.rawValue > $1.rawValue }.prefix(5))
        let recent = Date(timeIntervalSince1970: 1_800_000_000)
        for id in progressed {
            file.progress.append(PlaybackProgress(contentID: id, position: 1, duration: 2, updatedAt: recent))
        }
        file.watched = allWatched

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(file).write(to: directories.libraryFile)

        let store = LibraryStore(directories: directories)
        await store.awaitDiskLoad()
        #expect(store.watchlist == Array(file.watchlist.prefix(LibraryStore.maxWatchlist)))
        #expect(store.dismissed == Array(file.dismissed.prefix(LibraryStore.maxDismissed)))
        #expect(store.favoriteChannels == Array(file.favoriteChannels.prefix(LibraryStore.maxFavoriteChannels)))
        #expect(store.history.map(\.id) == file.history.prefix(LibraryStore.maxHistory).map(\.id))
        #expect(store.preferredVariants.count == LibraryStore.maxPreferredEntries)
        #expect(store.preferredVariants[TitleID(rawValue: "k0")] != nil)
        #expect(store.preferredVariants[TitleID(rawValue: "k\(LibraryStore.maxPreferredEntries + 1)")] == nil)
        #expect(store.preferredChannelVariants["g0"] != nil)
        #expect(store.preferredChannelVariants["g\(LibraryStore.maxPreferredEntries + 1)"] == nil)

        let rest = allWatched.filter { !progressed.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        let expectedWatched = progressed.union(rest.prefix(LibraryStore.maxWatched - progressed.count))
        #expect(store.watched == expectedWatched)
        #expect(store.watched.count == LibraryStore.maxWatched)
        for id in progressed {
            #expect(store.watched.contains(id), "fresh progress must survive the cap")
        }
    }

    @Test func concurrentSeriesCastLookupsShareOneRequest() async throws {
        let host = StubURLProtocol.uniqueHost("tvmaze-dedup")
        StubURLProtocol.register(host: host) { request in
            Thread.sleep(forTimeInterval: 0.15)
            switch request.url?.path {
            case "/search/shows":
                return .json(#"[{"show":{"id":51,"name":"Lupin","premiered":"2021-01-08","url":"https://www.tvmaze.com/shows/51/lupin"}}]"#)
            case "/shows/51/cast":
                return .json(#"[{"person":{"id":4,"name":"Omar Sy","image":null},"character":{"name":"Assane Diop"}}]"#)
            default:
                return .text("Missing", status: 404)
            }
        }
        defer { StubURLProtocol.unregister(host: host) }
        let repository = SeriesCastRepository(session: StubURLProtocol.session(), host: host)
        async let first = repository.cast(title: "Lupin", year: 2021)
        async let second = repository.cast(title: "Lupin", year: 2021)
        let (a, b) = await (first, second)
        #expect(a?.people.count == 1)
        #expect(b?.people.count == 1)
        #expect(StubURLProtocol.requestCount(host: host) == 2, "one search + one cast request, shared")
    }

    @Test func concurrentEPGRefreshesShareOneDownload() async throws {
        let host = StubURLProtocol.uniqueHost("epg-dedup")
        StubURLProtocol.register(host: host) { _ in
            Thread.sleep(forTimeInterval: 0.15)
            return .text(Self.xmltvBody)
        }
        defer { StubURLProtocol.unregister(host: host) }
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let repository = EPGRepository(directories: directories, credentials: InMemoryCredentialStore(), session: StubURLProtocol.session())
        let source = Source(id: "epg-dedup-src", name: "Nova", kind: .m3uURL, serverURL: URL(string: "https://\(host)/list.m3u"))
        let feed = URL(string: "https://\(host)/epg.xml")!
        async let first = repository.refresh(source, playlistEPGURLs: [feed])
        async let second = repository.refresh(source, playlistEPGURLs: [feed])
        let (a, b) = try await (first, second)
        #expect(a.programCount == b.programCount)
        #expect(StubURLProtocol.requestCount(host: host) == 1, "one XMLTV download shared by both callers")
        #expect(await repository.lastFetched(source.id) != nil)
    }

    @Test func epgRefreshDownloadsFeedsInParallelAndMergesThem() async throws {
        let host = StubURLProtocol.uniqueHost("epg-parallel")
        StubURLProtocol.register(host: host) { request in
            Thread.sleep(forTimeInterval: 0.05)
            return .text(request.url?.lastPathComponent == "a.xml" ? Self.xmltvBodyA : Self.xmltvBodyB)
        }
        defer { StubURLProtocol.unregister(host: host) }
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let repository = EPGRepository(directories: directories, credentials: InMemoryCredentialStore(), session: StubURLProtocol.session())
        let source = Source(id: "epg-parallel-src", name: "Nova", kind: .m3uURL, serverURL: URL(string: "https://\(host)/list.m3u"))
        let guide = try await repository.refresh(source, playlistEPGURLs: [
            URL(string: "https://\(host)/a.xml")!, URL(string: "https://\(host)/b.xml")!,
        ])
        #expect(StubURLProtocol.requestCount(host: host) == 2)
        #expect(guide.programCount == 2, "one programme per feed, merged")
        #expect(Set(guide.allPrograms.map(\.channelID)) == ["ch.a", "ch.b"])
    }

    /// Feeds download concurrently but merge in URL order: on a same-start conflict the
    /// earlier feed must win, whichever response arrived first.
    @Test(arguments: [
        (["a", "b"], "A", "A-Nom"),
        (["b", "a"], "B", "B-Nom"),
    ])
    func epgMergeKeepsEarlierFeedOnSameStartConflict(feedOrder: [String], expectedTitle: String, expectedChannelName: String) async throws {
        let host = StubURLProtocol.uniqueHost("epg-order-\(feedOrder.joined())")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        // Identical start/stop in both feeds so the conflict is exact.
        let start = formatter.string(from: Date.now.addingTimeInterval(-1_800))
        let stop = formatter.string(from: Date.now.addingTimeInterval(1_800))
        @Sendable func body(_ tag: String) -> String {
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <tv>
              <channel id="ch.a"><display-name>\(tag)-Nom</display-name></channel>
              <programme start="\(start)" stop="\(stop)" channel="ch.a"><title>\(tag)</title></programme>
            </tv>
            """
        }
        StubURLProtocol.register(host: host) { request in
            .text(request.url?.lastPathComponent == "a.xml" ? body("A") : body("B"))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let repository = EPGRepository(directories: directories, credentials: InMemoryCredentialStore(), session: StubURLProtocol.session())
        let source = Source(id: "epg-order-src", name: "Nova", kind: .m3uURL, serverURL: URL(string: "https://\(host)/list.m3u"))
        let feeds = try feedOrder.map { try #require(URL(string: "https://\(host)/\($0).xml")) }
        let guide = try await repository.refresh(source, playlistEPGURLs: feeds)

        let interval = DateInterval(start: .distantPast, end: .distantFuture)
        let programs = guide.programs(forEPGID: "ch.a", in: interval)
        #expect(programs.count == 1, "same-start duplicates collapse to the earlier feed's programme")
        #expect(programs.first?.title == expectedTitle)
        #expect(guide.xmltvChannel(forEPGID: "ch.a")?.displayNames.first == expectedChannelName)
    }

    // MARK: - XMLTV fixtures (dates inside the refresh window)

    private static var xmltvBody: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let now = Date.now
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch.a"><display-name>Chaîne A</display-name></channel>
          <programme start="\(formatter.string(from: now.addingTimeInterval(-1_800)))" stop="\(formatter.string(from: now.addingTimeInterval(1_800)))" channel="ch.a"><title>Journal</title></programme>
        </tv>
        """
    }

    private static var xmltvBodyA: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let now = Date.now
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch.a"><display-name>Chaîne A</display-name></channel>
          <programme start="\(formatter.string(from: now.addingTimeInterval(-1_800)))" stop="\(formatter.string(from: now.addingTimeInterval(1_800)))" channel="ch.a"><title>A</title></programme>
        </tv>
        """
    }

    private static var xmltvBodyB: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss Z"
        let now = Date.now
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <channel id="ch.b"><display-name>Chaîne B</display-name></channel>
          <programme start="\(formatter.string(from: now.addingTimeInterval(-1_800)))" stop="\(formatter.string(from: now.addingTimeInterval(1_800)))" channel="ch.b"><title>B</title></programme>
        </tv>
        """
    }
}
