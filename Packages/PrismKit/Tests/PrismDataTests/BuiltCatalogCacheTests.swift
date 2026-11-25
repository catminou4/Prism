import Foundation
import PrismCore
import Testing
@testable import PrismData

private func expectSameCatalog(_ actual: Catalog, _ expected: Catalog, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual.sources == expected.sources, sourceLocation: sourceLocation)
    #expect(actual.channels == expected.channels, sourceLocation: sourceLocation)
    #expect(actual.movies == expected.movies, sourceLocation: sourceLocation)
    #expect(actual.series == expected.series, sourceLocation: sourceLocation)
    #expect(actual.liveCategories == expected.liveCategories, sourceLocation: sourceLocation)
    #expect(actual.movieCategories == expected.movieCategories, sourceLocation: sourceLocation)
    #expect(actual.seriesCategories == expected.seriesCategories, sourceLocation: sourceLocation)
    #expect(actual.indexes.hasTaggedEditions == expected.indexes.hasTaggedEditions, sourceLocation: sourceLocation)
    #expect(actual.indexes.hasMalformedMediaContentIDs == expected.indexes.hasMalformedMediaContentIDs, sourceLocation: sourceLocation)
    #expect(actual.indexes.categories == expected.indexes.categories, sourceLocation: sourceLocation)
    #expect(actual.indexes.sourceIndex == expected.indexes.sourceIndex, sourceLocation: sourceLocation)
    #expect(actual.indexes.categoryGroups == expected.indexes.categoryGroups, sourceLocation: sourceLocation)
    #expect(actual.indexes.categoryToGroup == expected.indexes.categoryToGroup, sourceLocation: sourceLocation)
    #expect(actual.indexes.movieByTitleID == expected.indexes.movieByTitleID, sourceLocation: sourceLocation)
    #expect(actual.indexes.seriesByTitleID == expected.indexes.seriesByTitleID, sourceLocation: sourceLocation)
    #expect(actual.indexes.movieByContent == expected.indexes.movieByContent, sourceLocation: sourceLocation)
    #expect(actual.indexes.seriesByContent == expected.indexes.seriesByContent, sourceLocation: sourceLocation)
    #expect(actual.indexes.channelByContent == expected.indexes.channelByContent, sourceLocation: sourceLocation)
    #expect(actual.indexes.channelByGroupID == expected.indexes.channelByGroupID, sourceLocation: sourceLocation)
    #expect(actual.indexes.categoryLanguages == expected.indexes.categoryLanguages, sourceLocation: sourceLocation)
    #expect(actual.indexes.groupMembers == expected.indexes.groupMembers, sourceLocation: sourceLocation)
    #expect(actual.indexes.featuredMovies == expected.indexes.featuredMovies, sourceLocation: sourceLocation)
    #expect(actual.indexes.featuredSeries == expected.indexes.featuredSeries, sourceLocation: sourceLocation)
    #expect(actual.indexes.topRatedMovies == expected.indexes.topRatedMovies, sourceLocation: sourceLocation)
    #expect(actual.indexes.topRatedSeries == expected.indexes.topRatedSeries, sourceLocation: sourceLocation)
}

private func makeFixture() -> (sources: [Source], catalogs: [SourceCatalog]) {
    let a = Fixture.source(Fixture.a, "Source À")
    let b = Fixture.source(Fixture.b, "Source B")
    let movieCategories = [
        Fixture.category(Fixture.a, .movie, "action", "Action", sort: 2),
        Fixture.category(Fixture.a, .movie, "art", "Art et essai", sort: 1),
    ]
    let seriesCategories = [Fixture.category(Fixture.a, .series, "drama", "Drame", sort: 1)]
    let liveCategories = [Fixture.category(Fixture.a, .live, "news", "Infos", sort: 1)]
    let movieCategory = Fixture.categoryID(Fixture.a, .movie, "action")
    let seriesCategory = Fixture.categoryID(Fixture.a, .series, "drama")
    let liveCategory = Fixture.categoryID(Fixture.a, .live, "news")
    let movieA = Fixture.movie(
        Fixture.a, "42", "Le Film Étrange", year: 2020, quality: .uhd,
        raw: "FR: LE FILM ETRANGE (2020) MULTI 4K", category: movieCategory,
        poster: "poster with space.jpg", backdrop: "backdrop.jpg", plot: "Accents é è ê — Unicode.",
        genres: ["Action", "Science-fiction"], rating: 8.5,
        added: Fixture.reference.addingTimeInterval(-123.25), tmdbID: 42
    )
    let movieB = Fixture.movie(
        Fixture.b, "b42", "Le Film Étrange", year: 2020, quality: .hd,
        raw: "LE FILM ÉTRANGE 2020 VOSTFR", category: nil,
        plot: "Duplicate variant", genres: ["Action"], rating: 8.1,
        added: Fixture.reference.addingTimeInterval(-10), tmdbID: 42
    )
    let seriesA = Fixture.series(
        Fixture.a, "s1", "La Série", year: 2022, quality: .fhd,
        category: seriesCategory, poster: "series.jpg", plot: "Une série.",
        genres: ["Drame"], rating: 9.0, added: Fixture.reference, tmdbID: 99,
        seasons: Fixture.seasons(series: "s1", source: Fixture.a, counts: [2, 1])
    )
    let channels = [
        Fixture.channel(Fixture.a, "c1", "Chaîne Info", number: 1, quality: .hd, category: liveCategory, epg: "info.fr", logo: "logo.png"),
        Fixture.channel(Fixture.b, "c1", "Chaîne Info", number: 101, quality: .sd, epg: "info.fr"),
    ]
    var first = SourceCatalog(
        sourceID: Fixture.a, categories: movieCategories + seriesCategories + liveCategories,
        fetchedAt: Fixture.reference
    )
    first.movies = [movieA]
    first.series = [seriesA]
    first.channels = [channels[0]]
    var second = SourceCatalog(sourceID: Fixture.b, fetchedAt: Fixture.reference.addingTimeInterval(3))
    second.movies = [movieB]
    second.channels = [channels[1]]
    return ([a, b], [first, second])
}

struct BuiltCatalogCacheTests {
    @Test
    func artifactRoundTripIsByteForByteEquivalentToFreshBuild() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.caches); try? FileManager.default.removeItem(at: directories.root) }
        let (sources, catalogs) = makeFixture()
        let sourceCache = CatalogCache(directories: directories)
        for catalog in catalogs { try await sourceCache.save(catalog) }
        let options = CatalogBuildOptions(hideAdult: false, hiddenCategoryIDs: [Fixture.categoryID(Fixture.a, .movie, "art")])
        let built = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: options)
        let artifactCache = BuiltCatalogCache(directories: directories)
        await artifactCache.save(catalog: built, sources: sources, catalogs: catalogs, options: options, generation: UInt64(Date.now.timeIntervalSince1970 * 1_000_000))
        guard let decoded = await artifactCache.load(sources: sources, options: options) else {
            Issue.record("artifact did not validate/decode")
            return
        }
        expectSameCatalog(decoded, built)
    }

    @Test
    func artifactRoundTripMatchesLargerSyntheticBuild() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.caches); try? FileManager.default.removeItem(at: directories.root) }
        let fixture = Synthetic.catalogs(movies: 400, series: 120, channels: 180)
        let sourceCache = CatalogCache(directories: directories)
        for catalog in fixture.catalogs { try await sourceCache.save(catalog) }
        let options = CatalogBuildOptions()
        let built = await CatalogBuilder.build(sources: fixture.sources, catalogs: fixture.catalogs, options: options)
        let artifactCache = BuiltCatalogCache(directories: directories)
        await artifactCache.save(catalog: built, sources: fixture.sources, catalogs: fixture.catalogs, options: options, generation: UInt64(Date.now.timeIntervalSince1970 * 1_000_000))
        guard let decoded = await artifactCache.load(sources: fixture.sources, options: options) else {
            Issue.record("synthetic artifact did not validate/decode")
            return
        }
        expectSameCatalog(decoded, built)
    }


    @Test
    func artifactSupportsMissingSourceCacheAndInvalidatesWhenItAppears() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.caches); try? FileManager.default.removeItem(at: directories.root) }
        let (sources, catalogs) = makeFixture()
        let sourceCache = CatalogCache(directories: directories)
        try await sourceCache.save(catalogs[0])
        let options = CatalogBuildOptions()
        let built = await CatalogBuilder.build(sources: sources, catalogs: [catalogs[0]], options: options)
        let artifactCache = BuiltCatalogCache(directories: directories)
        await artifactCache.save(catalog: built, sources: sources, catalogs: [catalogs[0]], options: options, generation: 10)
        guard let decoded = await artifactCache.load(sources: sources, options: options) else {
            Issue.record("partial-input artifact did not validate/decode")
            return
        }
        expectSameCatalog(decoded, built)
        try await sourceCache.save(catalogs[1])
        #expect(await artifactCache.load(sources: sources, options: options) == nil)
    }


    @Test
    func artifactSupportsTheDeterministicDemoSource() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.caches); try? FileManager.default.removeItem(at: directories.root) }
        let (realSources, catalogs) = makeFixture()
        let demoSource = DemoContent.makeSource()
        let demoCatalog = DemoContent.makeCatalog(fetchedAt: .now)
        let sources = [demoSource] + realSources
        let inputs = [demoCatalog] + catalogs
        let sourceCache = CatalogCache(directories: directories)
        for catalog in catalogs { try await sourceCache.save(catalog) }
        let options = CatalogBuildOptions()
        let built = await CatalogBuilder.build(sources: sources, catalogs: inputs, options: options)
        let artifactCache = BuiltCatalogCache(directories: directories)
        await artifactCache.save(catalog: built, sources: sources, catalogs: inputs, options: options, generation: 20)
        guard let decoded = await artifactCache.load(sources: sources, options: options) else {
            Issue.record("demo-input artifact did not validate/decode")
            return
        }
        expectSameCatalog(decoded, built)
    }

    @Test
    func artifactEncodingIsDeterministicForFixedMeta() async throws {
        let fixture = Synthetic.catalogs(movies: 100, series: 40, channels: 50)
        let built = await CatalogBuilder.build(sources: fixture.sources, catalogs: fixture.catalogs)
        let meta = BuiltCatalogBinary.Meta(
            builderSemanticsVersion: 1, saveGeneration: 123, hideAdult: false, hiddenCategoryIDs: [],
            inputs: fixture.sources.map {
                BuiltCatalogBinary.InputFingerprint(
                    sourceID: $0.id, byteCount: 1, contentHash: 2
                )
            },
            sourceCount: fixture.sources.count,
            movieTitleCount: built.movies.count, movieVariantCount: built.movies.reduce(0) { $0 + $1.variants.count },
            seriesTitleCount: built.series.count, seriesVariantCount: built.series.reduce(0) { $0 + $1.variants.count },
            channelGroupCount: built.channels.count, channelVariantCount: built.channels.reduce(0) { $0 + $1.variants.count },
            categoryGroupCount: built.liveCategories.count + built.movieCategories.count + built.seriesCategories.count
        )
        async let first = BuiltCatalogCache.encodeArtifact(catalog: built, meta: meta)
        async let second = BuiltCatalogCache.encodeArtifact(catalog: built, meta: meta)
        let (a, b) = await (first, second)
        #expect(a != nil)
        #expect(a == b)
    }

    @Test
    func artifactRejectsChangedInputsOptionsAndSourceOrder() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.caches); try? FileManager.default.removeItem(at: directories.root) }
        let (sources, catalogs) = makeFixture()
        let sourceCache = CatalogCache(directories: directories)
        for catalog in catalogs { try await sourceCache.save(catalog) }
        let options = CatalogBuildOptions()
        let built = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: options)
        let artifactCache = BuiltCatalogCache(directories: directories)
        await artifactCache.save(catalog: built, sources: sources, catalogs: catalogs, options: options, generation: UInt64(Date.now.timeIntervalSince1970 * 1_000_000))
        #expect(await artifactCache.load(sources: sources, options: options) != nil)
        #expect(await artifactCache.load(sources: sources.reversed(), options: options) == nil)
        #expect(await artifactCache.load(sources: sources, options: .init(hideAdult: true)) == nil)
        var changed = catalogs[0]
        changed.fetchedAt = changed.fetchedAt.addingTimeInterval(1)
        try await sourceCache.save(changed)
        #expect(await artifactCache.load(sources: sources, options: options) == nil)
    }


    @Test
    func olderSaveNeverOverwritesFresherArtifact() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.caches); try? FileManager.default.removeItem(at: directories.root) }
        let (sources, catalogs) = makeFixture()
        let sourceCache = CatalogCache(directories: directories)
        for catalog in catalogs { try await sourceCache.save(catalog) }
        let options = CatalogBuildOptions()
        let built = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: options)
        let artifactCache = BuiltCatalogCache(directories: directories)
        await artifactCache.save(catalog: built, sources: sources, catalogs: catalogs, options: options, generation: 2_000)
        // Even if this older generation was already encoded when the fresher file landed, the
        // generation embedded in the on-disk meta must win the final write check.
        await artifactCache.save(catalog: built, sources: sources, catalogs: catalogs, options: options, generation: 1_000)
        guard let data = try? Data(contentsOf: directories.builtCatalogFile),
              let unpacked = SegmentedArchive.unpack(data), let first = unpacked.segments.first,
              let payload = CatalogCache.expandedBinaryPayload(of: first),
              let meta = BuiltCatalogBinary.decodeMeta(payload) else {
            Issue.record("missing artifact meta")
            return
        }
        #expect(meta.saveGeneration == 2_000)
    }

    @Test
    func corruptedArtifactBytesNeverCrashTheReader() async throws {
        let directories = AppDirectories.temporary()
        defer { try? FileManager.default.removeItem(at: directories.caches); try? FileManager.default.removeItem(at: directories.root) }
        let (sources, catalogs) = makeFixture()
        let sourceCache = CatalogCache(directories: directories)
        for catalog in catalogs { try await sourceCache.save(catalog) }
        let options = CatalogBuildOptions()
        let built = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: options)
        let artifactCache = BuiltCatalogCache(directories: directories)
        await artifactCache.save(catalog: built, sources: sources, catalogs: catalogs, options: options, generation: UInt64(Date.now.timeIntervalSince1970 * 1_000_000))
        let url = directories.builtCatalogFile
        guard let original = try? Data(contentsOf: url) else {
            Issue.record("missing artifact")
            return
        }
        // Truncations at structural boundaries and pseudo-random single-byte corruption.
        for length in [0, 1, 7, 12, original.count / 2, max(0, original.count - 1)] {
            try? original.prefix(length).write(to: url, options: [.atomic])
            _ = await artifactCache.load(sources: sources, options: options)
        }
        var rng = SplitMix64(seed: 99)
        for index in 0..<80 {
            var mutated = original
            let offset = Int.random(in: 0..<mutated.count, using: &rng)
            mutated[offset] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
            try? mutated.write(to: url, options: [.atomic])
            _ = await artifactCache.load(sources: sources, options: options)
            if index.isMultiple(of: 20) { await Task.yield() }
        }
    }
}
