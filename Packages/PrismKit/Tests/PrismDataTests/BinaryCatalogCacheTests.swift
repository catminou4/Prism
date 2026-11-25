import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Correctness oracle for the binary (v2) catalog cache format: exact round-trips, cross-format
/// equivalence with the JSON (v1) encoding, migration, and corruption resistance.
@Suite("Binary catalog cache")
struct BinaryCatalogCacheTests {
    typealias F = Fixture

    // MARK: - Fixtures

    /// A movie with every field populated, including the awkward ones: empty strings distinct
    /// from nil, unicode in titles, long plots, odd dates, fractional ratings, repeated
    /// tag/genre lists, non-empty headers.
    static func fullMovie(_ source: SourceID, _ id: String) -> Movie {
        Movie(
            sourceID: source, nativeID: id, title: "Le Fabuleux Destin d'Amélie Poulain 🎬",
            rawName: "FR| Le Fabuleux Destin d'Amélie Poulain 🎬 (2001) MULTi 2160p",
            year: 2001,
            posterURL: URL(string: "https://img.example.com/poster/\(id).jpg"),
            backdropURL: URL(string: "https://img.example.com/backdrop/\(id).jpg"),
            plot: "Amélie, une jeune serveuse dans un bar de Montmartre, observe les gens. "
                + String(repeating: "Une longue intrigue. ", count: 40),
            genres: ["Comédie", "Romance"], rating: 8.273, durationSeconds: 7_320,
            cast: ["Audrey Tautou", "Mathieu Kassovitz", "Rufus", "Lorella Cravotta"],
            director: "Jean-Pierre Jeunet", categoryID: "\(source.rawValue):movie:42",
            streamURL: URL(string: "http://vod.example.com/\(id).mkv")!,
            containerExtension: "mkv", quality: .uhd, tags: ["FR", "MULTI", "HEVC"],
            addedAt: Date(timeIntervalSinceReferenceDate: 817_305_875.587752),
            tmdbID: 194, trailerURL: URL(string: "https://youtube.com/watch?v=abc"),
            isAdult: true, httpHeaders: ["User-Agent": "VLC/3.0.20", "Referer": "http://x.example.com"]
        )
    }

    /// A movie with nothing optional set: nil everywhere, empty strings where they differ.
    static func bareMovie(_ source: SourceID, _ id: String) -> Movie {
        Movie(sourceID: source, nativeID: "", title: "", rawName: "", streamURL: URL(string: "http://x")!, quality: .unknown)
    }

    static func fullChannel(_ source: SourceID, _ id: String) -> Channel {
        Channel(
            sourceID: source, nativeID: id, name: "TF1 Séries Films 🎥", rawName: "FR| TF1 SÉRIES FILMS HEVC",
            number: 42, logoURL: URL(string: "https://logos.example.com/tf1.png"),
            categoryID: "\(source.rawValue):live:7", epgID: "tf1seriesfilms.fr",
            streamURL: URL(string: "http://live.example.com/\(id).m3u8")!,
            alternateStreamURL: URL(string: "http://live.example.com/\(id).ts"),
            quality: .fhd, tags: ["FR", "HEVC"],
            catchup: Catchup(mode: .xtream, days: 7, template: "?utc={utc}&lutc={lutc}"),
            isAdult: true, httpHeaders: ["http-user-agent": "Prism/1.0"]
        )
    }

    static func fullSeries(_ source: SourceID, _ id: String, withSeasons: Bool) -> Series {
        Series(
            sourceID: source, nativeID: id, title: "  🇫🇷", rawName: "EN - Downton Abbey (2010)",
            year: 2010, posterURL: URL(string: "https://img.example.com/s.jpg"),
            backdropURL: URL(string: "https://img.example.com/sb.jpg"),
            plot: "Une chronique de la vie des Crawley.", genres: ["Drame", "Historique"],
            rating: 8.7, cast: ["Hugh Bonneville"], director: "Julian Fellowes",
            categoryID: "\(source.rawValue):series:3", quality: .hd, tags: ["EN"],
            addedAt: Date(timeIntervalSinceReferenceDate: -37_581_983.25), tmdbID: 33_907,
            trailerURL: URL(string: "https://youtube.com/watch?v=xyz"), isAdult: false,
            seasons: withSeasons ? [
                Season(number: 1, name: "Saison 1", posterURL: URL(string: "https://img.example.com/s1.jpg"), overview: "Première saison.", episodes: [
                    Episode(
                        seriesID: ContentID(source: source, kind: .series, nativeID: id),
                        sourceID: source, nativeID: "\(id)-e1", season: 1, number: 1, title: "Pilot 🎬",
                        plot: "Le premier épisode.", durationSeconds: 3_600,
                        stillURL: URL(string: "https://img.example.com/e1.jpg"),
                        streamURL: URL(string: "http://vod.example.com/e1.mkv")!,
                        containerExtension: "mkv",
                        airDate: Date(timeIntervalSinceReferenceDate: 100_000_000.125),
                        rating: 9.125, httpHeaders: ["User-Agent": "x"]
                    ),
                    Episode(
                        seriesID: ContentID(source: source, kind: .series, nativeID: id),
                        sourceID: source, nativeID: "", season: 0, number: -3, title: "",
                        streamURL: URL(string: "http://vod.example.com/e2")!
                    ),
                ]),
                Season(number: -1, episodes: []),
            ] : nil
        )
    }

    /// A catalog touching every type and every edge case at once.
    static func richCatalog(source: SourceID = F.a) -> SourceCatalog {
        var catalog = SourceCatalog(
            sourceID: source,
            categories: [
                F.category(source, .movie, "42", "Films 🎬", adult: true, sort: -5),
                F.category(source, .live, "", ""),
                F.category(source, .series, "x", "Séries", sort: Int.max - 1),
            ],
            channels: [
                Self.fullChannel(source, "ch1"),
                Channel(sourceID: source, nativeID: "ch2", name: "", streamURL: URL(string: "http://x")!),
                Self.fullChannel(source, "ch3"),
                // Every catchup mode.
                Channel(sourceID: source, nativeID: "c-def", name: "a", streamURL: URL(string: "http://x")!, catchup: Catchup(mode: .default, days: 0)),
                Channel(sourceID: source, nativeID: "c-app", name: "b", streamURL: URL(string: "http://x")!, catchup: Catchup(mode: .append, days: -2, template: "")),
                Channel(sourceID: source, nativeID: "c-shi", name: "c", streamURL: URL(string: "http://x")!, catchup: Catchup(mode: .shift, days: 1)),
                Channel(sourceID: source, nativeID: "c-flu", name: "d", streamURL: URL(string: "http://x")!, catchup: Catchup(mode: .flussonic, days: 999)),
            ],
            movies: [Self.fullMovie(source, "m1"), Self.bareMovie(source, "m2"), Self.fullMovie(source, "m1")],
            series: [Self.fullSeries(source, "s1", withSeasons: true), Self.fullSeries(source, "s2", withSeasons: false)],
            account: XtreamAccount(
                username: "u", status: "Active", isActive: true, isTrial: true,
                expiresAt: Date(timeIntervalSinceReferenceDate: 820_018_800),
                createdAt: Date(timeIntervalSinceReferenceDate: -1), maxConnections: 3, activeConnections: 0,
                allowedOutputFormats: ["m3u8", "ts"], serverTimeZone: "Europe/Paris",
                serverURL: URL(string: "http://server.example.com:8080")
            ),
            fetchedAt: Date(timeIntervalSinceReferenceDate: 817_305_875.587752)
        )
        // Non-canonical ids (mutated after init) must survive exactly.
        catalog.movies[0].id = ContentID(rawValue: "totally-foreign-id")
        catalog.channels[1].categoryID = ""
        return catalog
    }

    // MARK: - Round-trip oracle

    @Test func binaryRoundTripIsExact() async throws {
        let catalog = Self.richCatalog()
        let data = try await CatalogCache.encode(catalog, version: 2)
        #expect(CatalogCache.embeddedVersion(of: data) == 2)
        let decoded = try #require(await CatalogCache.decode(data, version: 2))
        expectEqual(decoded, catalog)
    }

    @Test func binaryRoundTripEmptyCatalog() async throws {
        let catalog = SourceCatalog(sourceID: F.a, fetchedAt: F.reference)
        let data = try await CatalogCache.encode(catalog, version: 2)
        let decoded = try #require(await CatalogCache.decode(data, version: 2))
        expectEqual(decoded, catalog)
    }

    /// Extreme scalar values: Int min/max, negative years, zero/negative durations,
    /// exact-double ratings, dates far in the past/future.
    @Test func binaryRoundTripExtremeScalars() async throws {
        var movie = Self.bareMovie(F.a, "x")
        movie.year = Int.min + 1
        movie.rating = 0.0
        movie.durationSeconds = -1
        movie.tmdbID = Int.max
        movie.addedAt = Date(timeIntervalSinceReferenceDate: -62_135_596_800) // year 0-ish
        var other = Self.bareMovie(F.a, "y")
        other.year = 0
        other.rating = -0.0 // signed zero must survive bit-exactly
        other.durationSeconds = 0
        other.addedAt = Date(timeIntervalSinceReferenceDate: 62_135_596_800)
        var series = Self.fullSeries(F.a, "s", withSeasons: true)
        series.rating = 1.0 / 3.0
        let catalog = SourceCatalog(sourceID: F.a, movies: [movie, other], series: [series], fetchedAt: F.reference)
        let data = try await CatalogCache.encode(catalog, version: 2)
        let decoded = try #require(await CatalogCache.decode(data, version: 2))
        expectEqual(decoded, catalog)
        #expect(decoded.movies[1].rating?.bitPattern == (-0.0).bitPattern)
        #expect(decoded.series[0].rating == 1.0 / 3.0)
    }

    /// NaN and infinity can never come back from a v1 archive (JSON refuses them), but the
    /// binary format itself must not lose them: doubles are stored as exact bit patterns.
    @Test func binaryRoundTripNonFiniteDoubles() async throws {
        var movie = Self.bareMovie(F.a, "x")
        movie.rating = Double.nan
        var other = Self.bareMovie(F.a, "y")
        other.rating = Double.infinity
        var third = Self.bareMovie(F.a, "z")
        third.rating = -Double.infinity
        let catalog = SourceCatalog(sourceID: F.a, movies: [movie, other, third], fetchedAt: F.reference)
        let data = try await CatalogCache.encode(catalog, version: 2)
        let decoded = try #require(await CatalogCache.decode(data, version: 2))
        #expect(decoded.movies[0].rating?.isNaN == true)
        #expect(decoded.movies[1].rating == .infinity)
        #expect(decoded.movies[2].rating == -.infinity)
    }

    /// Empty strings and nil are different states of the same field; both must round-trip.
    @Test func binaryRoundTripEmptyStringVersusNil() async throws {
        var a = Self.bareMovie(F.a, "a")
        a.plot = ""
        a.director = nil
        var b = Self.bareMovie(F.a, "b")
        b.plot = nil
        b.director = ""
        var channel = Channel(sourceID: F.a, nativeID: "c", name: "", streamURL: URL(string: "http://x")!)
        channel.epgID = ""
        channel.$logoURL = ""
        channel.tags = [""]
        let catalog = SourceCatalog(sourceID: F.a, channels: [channel], movies: [a, b], fetchedAt: F.reference)
        let data = try await CatalogCache.encode(catalog, version: 2)
        let decoded = try #require(await CatalogCache.decode(data, version: 2))
        #expect(decoded.movies[0].plot == "")
        #expect(decoded.movies[0].director == nil)
        #expect(decoded.movies[1].plot == nil)
        #expect(decoded.movies[1].director == "")
        #expect(decoded.channels[0].epgID == "")
        #expect(decoded.channels[0].$logoURL == "")
        #expect(decoded.channels[0].tags == [""])
        expectEqual(decoded, catalog)
    }

    /// Unicode stress: emoji sequences, combining marks, RTL scripts, zero-width joiners.
    /// They are just UTF-8 bytes to the format, but equality must be exact anyway.
    @Test func binaryRoundTripUnicode() async throws {
        let titles = ["👨‍👩‍👧‍👦 famille", "e\u{0301} combining", "برامج منوعه", "", "\u{202E}rtl override", "🏳️‍🌈"]
        let movies = titles.enumerated().map { index, title in
            Movie(sourceID: F.a, nativeID: "\(index)", title: title, rawName: title, streamURL: URL(string: "http://x/\(index)")!)
        }
        let catalog = SourceCatalog(sourceID: F.a, movies: movies, fetchedAt: F.reference)
        let data = try await CatalogCache.encode(catalog, version: 2)
        let decoded = try #require(await CatalogCache.decode(data, version: 2))
        #expect(decoded.movies.map(\.title) == titles)
        expectEqual(decoded, catalog)
    }

    // MARK: - Cross-format equivalence

    /// The same logical catalog encoded as v1-JSON and v2-binary must decode to the exact
    /// same value — the migration is value-preserving.
    @Test func crossFormatEquivalence() async throws {
        let catalog = Self.richCatalog()
        let v1 = try await CatalogCache.encode(catalog, version: 1)
        let v2 = try await CatalogCache.encode(catalog, version: 2)
        #expect(CatalogCache.embeddedVersion(of: v1) == 1)
        #expect(CatalogCache.embeddedVersion(of: v2) == 2)
        let fromV1 = try #require(await CatalogCache.decode(v1, version: 2))
        let fromV2 = try #require(await CatalogCache.decode(v2, version: 2))
        expectEqual(fromV1, fromV2)
        // And both match the original bit for bit.
        expectEqual(fromV2, catalog)
    }

    /// Migration fidelity on the exact path the app takes: decode the v1 archive, re-encode
    /// the *decoded* catalog as v2, decode again — no drift.
    @Test func migrationReencodeIsStable() async throws {
        let catalog = Self.richCatalog()
        let v1 = try await CatalogCache.encode(catalog, version: 1)
        let migrated = try #require(await CatalogCache.decode(v1, version: 2))
        let v2 = try await CatalogCache.encode(migrated, version: 2)
        let remigrated = try #require(await CatalogCache.decode(v2, version: 2))
        expectEqual(remigrated, migrated)
        // Encoding is deterministic enough that a re-migration changes nothing semantically.
        let v2again = try await CatalogCache.encode(remigrated, version: 2)
        let decodedAgain = try #require(await CatalogCache.decode(v2again, version: 2))
        expectEqual(decodedAgain, migrated)
    }

    // MARK: - Migration through the cache

    @Test func loadMigratesV1ArchiveToV2() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let catalog = Self.richCatalog()

        // Write a v1 archive through the v1 encode path, as the old app version would have.
        let v1Data = try await CatalogCache.encode(catalog, version: 1)
        try v1Data.write(to: directories.catalogCacheFile(for: catalog.sourceID), options: [.atomic])

        // The production cache reads it, and migration replaces it with a v2 file.
        let cache = CatalogCache(directories: directories)
        let loaded = try #require(await cache.load(catalog.sourceID))
        expectEqual(loaded, catalog)

        // Migration is a background task: wait for the v2 file to appear.
        let url = directories.catalogCacheFile(for: catalog.sourceID)
        var migratedData: Data?
        for _ in 0..<200 {
            if let data = try? Data(contentsOf: url), CatalogCache.embeddedVersion(of: data) == 2 {
                migratedData = data
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let rewritten = try #require(migratedData, "the v1 archive should be re-saved as v2 in the background")
        let reloaded = try #require(await CatalogCache.decode(rewritten, version: 2, expecting: catalog.sourceID))
        expectEqual(reloaded, catalog)
    }

    /// A newer write must never be overwritten by a stale migration: the migration bails out
    /// when the file changed since the load.
    @Test func migrationNeverOverwritesNewerSave() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let original = Self.richCatalog()

        let v1Data = try await CatalogCache.encode(original, version: 1)
        try v1Data.write(to: directories.catalogCacheFile(for: original.sourceID), options: [.atomic])

        let cache = CatalogCache(directories: directories)
        _ = try #require(await cache.load(original.sourceID))

        // Race the migration: immediately overwrite with a fresher catalog through save.
        var fresher = original
        fresher.movies.append(Self.bareMovie(original.sourceID, "fresh"))
        try await cache.save(fresher)

        // Even after waiting, the on-disk catalog must be the fresher one.
        try await Task.sleep(for: .milliseconds(800))
        let reloaded = try #require(await cache.load(original.sourceID))
        #expect(reloaded.movies.count == fresher.movies.count)
    }

    /// v1 archives are *kept* by the purge (they are migratable); unknown versions are not.
    @Test func purgeKeepsMigratableVersions() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.root.deletingLastPathComponent()) }
        let directory = directories.caches.appending(path: "Catalogs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let catalog = SourceCatalog(sourceID: F.a, fetchedAt: F.reference)
        let v1 = try await CatalogCache.encode(catalog, version: 1)
        let v2 = try await CatalogCache.encode(catalog, version: 2)
        let v3 = try await CatalogCache.encode(catalog, version: 3)
        for (name, data) in [("one.catalog", v1), ("two.catalog", v2), ("three.catalog", v3)] {
            try data.write(to: directory.appending(path: name))
        }

        await Task.detached(priority: .utility) {
            SegmentedArchive.purgeObsoleteFiles(in: directory, versions: CatalogCache.readableVersions, suffix: "catalog")
        }.value

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "one.catalog").path(percentEncoded: false)), "v1 is migratable: kept")
        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "two.catalog").path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "three.catalog").path(percentEncoded: false)), "undecodable future versions are purged")
    }

    /// Future archives (written by a newer app) must be ignored, not misdecoded.
    @Test func futureVersionIsRejected() async throws {
        let catalog = Self.richCatalog()
        let v3 = try await CatalogCache.encode(catalog, version: 3)
        #expect(await CatalogCache.decode(v3, version: 2) == nil)
        // A version-0 header is equally foreign.
        var v0 = try await CatalogCache.encode(catalog, version: 2)
        v0[4] = 0; v0[5] = 0; v0[6] = 0; v0[7] = 0
        #expect(await CatalogCache.decode(v0, version: 2) == nil)
    }

    // MARK: - Corruption resistance

    @Test func truncatedPayloadsFailGracefully() async throws {
        let catalog = Self.richCatalog()
        let data = try await CatalogCache.encode(catalog, version: 2)
        #expect(await CatalogCache.decode(data, version: 2) != nil)
        // Every truncation length must return nil without crashing — never a partial catalog.
        for length in [0, 4, 8, 11, 12, 100, data.count / 2, data.count - 1] {
            #expect(await CatalogCache.decode(data.prefix(length), version: 2) == nil, "truncated at \(length)")
        }
    }

    @Test func garbageBytesFailGracefully() async throws {
        var rng = SplitMix64(seed: 1)
        for _ in 0..<30 {
            let length = Int.random(in: 0...2_000, using: &rng)
            var garbage = Data(count: length)
            for index in garbage.indices { garbage[index] = UInt8(truncatingIfNeeded: rng.next()) }
            #expect(await CatalogCache.decode(garbage, version: 2) == nil)
        }
    }

    /// Absurd counts and lengths inside otherwise well-formed containers must fail, not
    /// allocate: a string-length field claiming gigabytes, an item count of billions.
    @Test func absurdCountsNeverAllocate() async throws {
        // Hand-craft a binary payload: valid codec byte, then a string table count of 2^32.
        var payload = Data([BinaryArchive.codecByte])
        var count: UInt64 = 1 << 32
        while count >= 0x80 {
            payload.append(UInt8(truncatingIfNeeded: count) | 0x80)
            count >>= 7
        }
        payload.append(UInt8(truncatingIfNeeded: count))
        #expect(BinaryArchive.decodeMovies(payload) == nil)
        #expect(BinaryArchive.decodeChannels(payload) == nil)
        #expect(BinaryArchive.decodeSeries(payload) == nil)
        #expect(BinaryArchive.decodeMeta(payload) == nil)

        // Valid codec byte, plausible small string count, then a string claiming 2^40 bytes.
        var crafted = Data([BinaryArchive.codecByte, 1]) // stringCount = 1
        var length: UInt64 = 1 << 40
        var encoded: [UInt8] = []
        while length >= 0x80 {
            encoded.append(UInt8(truncatingIfNeeded: length) | 0x80)
            length >>= 7
        }
        encoded.append(UInt8(truncatingIfNeeded: length))
        crafted.append(contentsOf: encoded)
        #expect(BinaryArchive.decodeMovies(crafted) == nil)
    }

    /// Bit-flip fuzz over a valid compressed archive: corrupting anything may return nil or —
    /// for flips in inert payload bytes — a catalog, but it must never crash and never block.
    @Test func bitFlipFuzzNeverCrashes() async throws {
        let catalog = Self.richCatalog()
        let data = try await CatalogCache.encode(catalog, version: 2)
        var rng = SplitMix64(seed: 42)
        var nilCount = 0
        var okCount = 0
        for _ in 0..<150 {
            var mutated = data
            let flips = Int.random(in: 1...3, using: &rng)
            for _ in 0..<flips {
                let position = Int.random(in: 0..<mutated.count, using: &rng)
                mutated[position] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
            }
            if await CatalogCache.decode(mutated, version: 2) == nil {
                nilCount += 1
            } else {
                okCount += 1
            }
        }
        // Most single-bit flips inside an LZFSE stream or a bitmask either break decompression
        // or validation; a few may land in inert string bytes. Both outcomes are acceptable —
        // the assertion here is only that the loop completed at all.
        #expect(nilCount + okCount == 150)
        print("[fuzz] bit flips: \(nilCount) rejected, \(okCount) still decodable out of 150")
    }

    /// Truncating inside the *binary* payload specifically (after decompression) exercises
    /// the reader bounds checks rather than the container's.
    @Test func binaryPayloadTruncation() async throws {
        let movies = (0..<100).map { Self.fullMovie(F.a, "m\($0)") }
        let payload = BinaryArchive.encodeMovies(movies[...])
        #expect(BinaryArchive.decodeMovies(payload)?.count == 100)
        for length in [1, 2, 5, payload.count / 2, payload.count - 1] {
            #expect(BinaryArchive.decodeMovies(payload.prefix(length)) == nil, "payload truncated at \(length)")
        }
    }

    /// A valid payload with trailing garbage must be rejected (the reader requires exact consumption).
    @Test func trailingGarbageIsRejected() async throws {
        let movies = [Self.fullMovie(F.a, "m0")]
        var payload = BinaryArchive.encodeMovies(movies[...])
        payload.append(0xFF)
        #expect(BinaryArchive.decodeMovies(payload) == nil)
    }

    // MARK: - Decoded-value sharing

    /// The table encoding must reproduce what `shareRepeatedValues()` bought the v1 path:
    /// equal lists and strings are the same instances after decode.
    @Test func decodedValuesAreShared() async throws {
        let tags = ["FR", "UHD", "MULTI", "this-tag-is-definitely-longer-than-fifteen-bytes"]
        let genre = ["some-genre-name-that-is-fairly-long"]
        let movies = (0..<200).map { index -> Movie in
            var movie = Self.bareMovie(F.a, "m\(index)")
            movie.tags = tags
            movie.genres = genre
            return movie
        }
        let catalog = SourceCatalog(sourceID: F.a, movies: movies, fetchedAt: F.reference)
        let data = try await CatalogCache.encode(catalog, version: 2)
        let decoded = try #require(await CatalogCache.decode(data, version: 2))
        #expect(decoded.movies.count == 200)
        // Same identity: one array buffer backs every copy.
        for index in 1..<200 {
            #expect(decoded.movies[index].tags == tags)
            // Unsafe identity check through withContiguousStorage — equal arrays that share
            // a buffer have the same base address.
            let same = decoded.movies[0].tags.withContiguousStorageIfAvailable { first in
                decoded.movies[index].tags.withContiguousStorageIfAvailable { other in
                    first.baseAddress == other.baseAddress
                }
            }
            #expect(same == true, "tag lists should share one buffer")
        }
    }

    // MARK: - Comparison helpers

    /// Exact field-by-field comparison. The models are `Equatable`/`Hashable`, so equality is
    /// already defined — but when a test fails, knowing *which* field drifted is the difference
    /// between minutes and hours; this helper pinpoints it.
    func expectEqual(_ lhs: SourceCatalog, _ rhs: SourceCatalog) {
        #expect(lhs.sourceID == rhs.sourceID, "sourceID")
        #expect(lhs.fetchedAt == rhs.fetchedAt, "fetchedAt")
        #expect(lhs.plotsCleaned == rhs.plotsCleaned, "plotsCleaned")
        #expect(lhs.account == rhs.account, "account")
        #expect(lhs.categories == rhs.categories, "categories")
        #expect(lhs.channels == rhs.channels, "channels differ")
        #expect(lhs.movies == rhs.movies, "movies differ")
        #expect(lhs.series == rhs.series, "series differ")
        guard lhs.channels == rhs.channels, lhs.movies == rhs.movies, lhs.series == rhs.series else {
            for (a, b) in zip(lhs.channels, rhs.channels) where a != b { diff(a, b, "channel"); break }
            for (a, b) in zip(lhs.movies, rhs.movies) where a != b { diff(a, b, "movie"); break }
            for (a, b) in zip(lhs.series, rhs.series) where a != b { diff(a, b, "series"); break }
            return
        }
    }

    private func diff(_ a: Channel, _ b: Channel, _ kind: String) {
        #expect(a.id == b.id, "\(kind) id: \(a.id) vs \(b.id)")
        #expect(a.sourceID == b.sourceID, "\(kind) sourceID")
        #expect(a.nativeID == b.nativeID, "\(kind) nativeID")
        #expect(a.name == b.name, "\(kind) name")
        #expect(a.rawName == b.rawName, "\(kind) rawName")
        #expect(a.number == b.number, "\(kind) number")
        #expect(a.$logoURL == b.$logoURL, "\(kind) logoURL")
        #expect(a.categoryID == b.categoryID, "\(kind) categoryID")
        #expect(a.epgID == b.epgID, "\(kind) epgID")
        #expect(a.$streamURL == b.$streamURL, "\(kind) streamURL")
        #expect(a.$alternateStreamURL == b.$alternateStreamURL, "\(kind) alternateStreamURL")
        #expect(a.quality == b.quality, "\(kind) quality")
        #expect(a.tags == b.tags, "\(kind) tags")
        #expect(a.catchup == b.catchup, "\(kind) catchup")
        #expect(a.isAdult == b.isAdult, "\(kind) isAdult")
        #expect(a.httpHeaders == b.httpHeaders, "\(kind) httpHeaders")
    }

    private func diff(_ a: Movie, _ b: Movie, _ kind: String) {
        #expect(a.id == b.id, "\(kind) id: \(a.id) vs \(b.id)")
        #expect(a.sourceID == b.sourceID, "\(kind) sourceID")
        #expect(a.nativeID == b.nativeID, "\(kind) nativeID")
        #expect(a.title == b.title, "\(kind) title")
        #expect(a.rawName == b.rawName, "\(kind) rawName")
        #expect(a.year == b.year, "\(kind) year")
        #expect(a.$posterURL == b.$posterURL, "\(kind) posterURL")
        #expect(a.$backdropURL == b.$backdropURL, "\(kind) backdropURL")
        #expect(a.plot == b.plot, "\(kind) plot")
        #expect(a.genres == b.genres, "\(kind) genres")
        #expect(a.rating == b.rating, "\(kind) rating")
        #expect(a.durationSeconds == b.durationSeconds, "\(kind) duration")
        #expect(a.cast == b.cast, "\(kind) cast")
        #expect(a.director == b.director, "\(kind) director")
        #expect(a.categoryID == b.categoryID, "\(kind) categoryID")
        #expect(a.$streamURL == b.$streamURL, "\(kind) streamURL")
        #expect(a.containerExtension == b.containerExtension, "\(kind) containerExtension")
        #expect(a.quality == b.quality, "\(kind) quality")
        #expect(a.tags == b.tags, "\(kind) tags")
        #expect(a.addedAt == b.addedAt, "\(kind) addedAt")
        #expect(a.tmdbID == b.tmdbID, "\(kind) tmdbID")
        #expect(a.$trailerURL == b.$trailerURL, "\(kind) trailerURL")
        #expect(a.isAdult == b.isAdult, "\(kind) isAdult")
        #expect(a.httpHeaders == b.httpHeaders, "\(kind) httpHeaders")
    }

    private func diff(_ a: Series, _ b: Series, _ kind: String) {
        #expect(a.id == b.id, "\(kind) id")
        #expect(a.title == b.title, "\(kind) title")
        #expect(a.rawName == b.rawName, "\(kind) rawName")
        #expect(a.year == b.year, "\(kind) year")
        #expect(a.plot == b.plot, "\(kind) plot")
        #expect(a.genres == b.genres, "\(kind) genres")
        #expect(a.rating == b.rating, "\(kind) rating")
        #expect(a.cast == b.cast, "\(kind) cast")
        #expect(a.seasons == b.seasons, "\(kind) seasons")
        #expect(a.tags == b.tags, "\(kind) tags")
        #expect(a.quality == b.quality, "\(kind) quality")
        #expect(a.$posterURL == b.$posterURL, "\(kind) posterURL")
        #expect(a.$backdropURL == b.$backdropURL, "\(kind) backdropURL")
        #expect(a.$trailerURL == b.$trailerURL, "\(kind) trailerURL")
    }
}
