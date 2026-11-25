import Foundation
import PrismCore
import Testing
@testable import PrismData

@Suite("Persistence stores")
struct StoreTests {
    typealias F = Fixture

    @Test func appDirectoriesCreateFoldersLazily() throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        #expect(!FileManager.default.fileExists(atPath: directories.root.path(percentEncoded: false)))
        let file = directories.catalogCacheFile(for: "weird/id:with spaces")
        #expect(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path(percentEncoded: false)))
        #expect(!file.lastPathComponent.contains("/"))
        #expect(file.lastPathComponent != directories.catalogCacheFile(for: "weird_id_with_spaces").lastPathComponent)
        #expect(directories.sourcesFile.lastPathComponent == "sources.json")
        #expect(AppDirectories.standard.root.lastPathComponent == "Prism")
    }

    @Test func sourceStoreRoundTrip() throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let store = SourceStore(directories: directories)
        #expect(store.load().isEmpty)
        let sources = [
            Source(id: "x1", name: "Atlas TV", kind: .xtream, serverURL: URL(string: "http://atlas.example:8080"), username: "louis",
                   epgTimeShiftHours: 1, tint: .purple, createdAt: F.reference, lastRefreshedAt: F.reference),
            Source(id: "m1", name: "Nova", kind: .m3uURL, serverURL: URL(string: "https://nova.example/list.m3u"), userAgent: "VLC/3.0", isEnabled: false, createdAt: F.reference),
        ]
        try store.save(sources)
        #expect(store.load() == sources)
    }

    @Test func catalogCacheRoundTripAndVersioning() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let catalog = SourceCatalog(
            sourceID: F.a,
            categories: [F.category(F.a, .movie, "1", "Action")],
            channels: [F.channel(F.a, "1", "TF1", number: 1, epg: "TF1.fr")],
            movies: [F.movie(F.a, "1", "Heat", year: 1995, quality: .hd, category: "1", genres: ["Action"], rating: 8.3, added: F.reference)],
            series: [F.series(F.a, "1", "Dark", seasons: F.seasons(series: "1", source: F.a, counts: [2, 3]))],
            account: XtreamAccount(username: "u", status: "Active", isActive: true, allowedOutputFormats: ["m3u8"]),
            fetchedAt: F.reference
        )
        let cache = CatalogCache(directories: directories)
        #expect(await cache.load(F.a) == nil)
        try await cache.save(catalog)
        let loaded = try #require(await cache.load(F.a))
        #expect(loaded.movies == catalog.movies)
        #expect(loaded.series == catalog.series)
        #expect(loaded.channels == catalog.channels)
        #expect(loaded.categories == catalog.categories)
        #expect(loaded.account == catalog.account)
        #expect(loaded.fetchedAt == catalog.fetchedAt)
        #expect(cache.cachedAt(F.a) != nil)

        // Archives written by a newer format than this build are ignored: they may use codecs
        // it does not have. Older-but-readable versions decode instead of being dropped.
        let foreign = try await CatalogCache.encode(catalog, version: CatalogCache.formatVersion + 1)
        try foreign.write(to: directories.catalogCacheFile(for: F.a), options: [.atomic])
        #expect(await cache.load(F.a) == nil, "a newer format version is ignored")

        await cache.remove(F.a)
        #expect(await cache.load(F.a) == nil)
    }

    /// Archives flagged `titlesRefined` skip the per-title migration pass on decode;
    /// archives written before the flag existed (no key → `nil`) still get it. The legacy
    /// fixtures here are version 1: JSON payloads are what those archives actually contain.
    @Test func catalogCacheTitleRefinementFlag() async throws {
        let rawTitle = "Narcos SPANISH MULTI SUB"
        let catalog = SourceCatalog(sourceID: F.a, movies: [F.movie(F.a, "1", rawTitle)])

        // New archives carry the flag: the stored title round-trips untouched.
        let flagged = try await CatalogCache.encode(catalog, version: 1)
        let flaggedSegments = try #require(SegmentedArchive.unpack(flagged, version: 1))
        let flaggedMeta = try #require(SegmentedArchive.decodeSegment(CatalogCache.Meta.self, from: flaggedSegments[0]))
        #expect(flaggedMeta.titlesRefined == true)
        let decodedFlagged = try #require(await CatalogCache.decode(flagged, version: CatalogCache.formatVersion))
        #expect(decodedFlagged.movies.first?.title == rawTitle)

        // Legacy archive: same payload, meta without the flag → decode refines once.
        let legacyMeta = CatalogCache.Meta(
            sourceID: F.a, categories: [], account: nil, fetchedAt: F.reference,
            channelCount: 0, movieCount: 1, seriesCount: 0, titlesRefined: nil
        )
        let metaSegment = try SegmentedArchive.encodeSegment(legacyMeta, tag: 0)
        let movieSegments = try await SegmentedArchive.encodeChunks(
            catalog.movies, tag: CatalogCache.Tag.movies.rawValue, chunkSize: CatalogCache.chunkSize
        )
        let legacy = SegmentedArchive.pack([metaSegment] + movieSegments, version: 1)
        let decodedLegacy = try #require(await CatalogCache.decode(legacy, version: CatalogCache.formatVersion))
        #expect(decodedLegacy.movies.first?.title == "Narcos")
    }

    /// Plots cleaned at import (`cleaningPlots`) keep their flag through the cache, and the
    /// builder then produces exactly the plots it produced from the raw text.
    @Test func cleanedPlotsRoundTripAndBuildIdentically() async throws {
        let mixed = "Une famille de Winden découvre un secret qui traverse les générations et le temps.\n\n"
            + "A family in Winden uncovers a secret that spans several generations and time itself."
        let messy = "  Deux  espaces   et\tune tabulation dans ce résumé un peu sale du fournisseur.  "
        let movies = [
            F.movie(F.a, "1", "Dark", year: 2017, plot: mixed),
            F.movie(F.a, "2", "Heat", year: 1995, plot: messy),
            F.movie(F.a, "3", "Heat", year: 1995, quality: .uhd, plot: mixed),
            F.movie(F.a, "4", "Vide", plot: "   "),
        ]
        let series = [F.series(F.a, "s1", "Dark", year: 2017, plot: mixed), F.series(F.a, "s2", "Dark", year: 2017, plot: messy)]
        let raw = SourceCatalog(sourceID: F.a, movies: movies, series: series)
        let cleaned = await raw.cleaningPlots()
        #expect(cleaned.plotsCleaned)
        #expect(cleaned.movies.map(\.plot) == movies.map { ProviderSynopsis.cleaned($0.plot) })
        #expect(cleaned.series.map(\.plot) == series.map { ProviderSynopsis.cleaned($0.plot) })

        let archive = try await CatalogCache.encode(cleaned, version: CatalogCache.formatVersion)
        let decoded = try #require(await CatalogCache.decode(archive, version: CatalogCache.formatVersion))
        #expect(decoded.plotsCleaned)
        let legacy = try #require(await CatalogCache.decode(
            try await CatalogCache.encode(raw, version: CatalogCache.formatVersion), version: CatalogCache.formatVersion
        ))
        #expect(!legacy.plotsCleaned, "raw catalogues keep being cleaned by the builder")

        let fromRaw = await F.build([F.source(F.a)], [raw])
        let fromCleaned = await F.build([F.source(F.a)], [decoded])
        #expect(fromRaw.movies.map(\.plot) == fromCleaned.movies.map(\.plot))
        #expect(fromRaw.series.map(\.plot) == fromCleaned.series.map(\.plot))
        #expect(fromRaw.movies.map(\.id) == fromCleaned.movies.map(\.id))
    }

    @Test func corruptedCacheIsIgnored() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        try Data("garbage".utf8).write(to: directories.catalogCacheFile(for: F.a))
        #expect(await CatalogCache(directories: directories).load(F.a) == nil)
        // Truncated archive.
        let catalog = SourceCatalog(sourceID: F.a, movies: (0..<30_000).map { F.movie(F.a, "\($0)", "Film \($0)", year: 2000) })
        let encoded = try await CatalogCache.encode(catalog, version: CatalogCache.formatVersion)
        #expect(await CatalogCache.decode(encoded, version: CatalogCache.formatVersion)?.movies.count == 30_000)
        #expect(await CatalogCache.decode(encoded.prefix(encoded.count - 10), version: CatalogCache.formatVersion) == nil)
        #expect(await CatalogCache.decode(encoded, version: CatalogCache.formatVersion, expecting: F.b) == nil)
        var bytes = try CompressedCodableFile.encode([1, 2, 3], version: 1, encoding: .json)
        bytes[bytes.count - 1] ^= 0xFF
        #expect(CompressedCodableFile.decode([Int].self, from: bytes, version: 1) == nil)
        let plist = try CompressedCodableFile.encode(["a": 1], version: 3, encoding: .binaryPropertyList)
        #expect(CompressedCodableFile.decode([String: Int].self, from: plist, version: 3) == ["a": 1])
    }

    @Test func epgCacheRoundTrip() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let cache = EPGCache(directories: directories)
        let programs = [F.program("tf1.fr", 0, 60, "Journal"), F.program("tf1.fr", 60, 120, "Film")]
        try await cache.save(.init(programs: programs, channels: [XMLTVChannel(id: "tf1.fr", displayNames: ["TF1"])], fetchedAt: F.reference), for: F.a)
        let entry = try #require(await cache.load(F.a))
        #expect(entry.programs == programs)
        #expect(entry.channels.first?.displayNames == ["TF1"])
        #expect(entry.fetchedAt == F.reference)
        await cache.remove(F.a)
        #expect(await cache.load(F.a) == nil)
    }

    @Test func inMemoryCredentials() throws {
        let store = InMemoryCredentialStore(passwords: [F.a: "secret"])
        #expect(store.password(for: F.a) == "secret")
        try store.setPassword("new", for: F.a)
        #expect(store.password(for: F.a) == "new")
        try store.setPassword(nil, for: F.a)
        #expect(store.password(for: F.a) == nil)
        try store.setSecret("tmdb-key", named: CredentialKeys.tmdb)
        #expect(store.tmdbKey == "tmdb-key")
        try store.setSecret("", named: CredentialKeys.tmdb)
        #expect(store.tmdbKey == nil)
    }

    /// Uses the real login keychain (separate test service, cleaned up). Works headless under
    /// `swift test` on a logged-in Mac; set `PRISM_SKIP_KEYCHAIN_TESTS=1` where no keychain is available (CI over SSH).
    @Test(.disabled(if: ProcessInfo.processInfo.environment["PRISM_SKIP_KEYCHAIN_TESTS"] == "1", "no login keychain available"))
    func keychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "app.prism.credentials.tests")
        let id = SourceID.generate()
        defer { try? store.setPassword(nil, for: id) }
        #expect(store.password(for: id) == nil)
        try store.setPassword("p@ss", for: id)
        #expect(store.password(for: id) == "p@ss")
        try store.setPassword("changed", for: id)
        #expect(store.password(for: id) == "changed")
        try store.setPassword(nil, for: id)
        #expect(store.password(for: id) == nil)
        try store.setSecret("tmdb-test", named: "tmdb-\(id.rawValue)")
        #expect(store.secret(named: "tmdb-\(id.rawValue)") == "tmdb-test")
        try store.setSecret(nil, named: "tmdb-\(id.rawValue)")
        #expect(store.secret(named: "tmdb-\(id.rawValue)") == nil)
    }
}
