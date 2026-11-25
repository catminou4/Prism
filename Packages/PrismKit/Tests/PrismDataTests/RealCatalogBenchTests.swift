import Foundation
import PrismCore
import Testing
@testable import PrismData

/// Measures the launch pipeline against the real catalog cached by the configured app
/// (read-only). Run with `PRISM_REAL_BENCH=1`; skipped anywhere the container cache is absent.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_REAL_BENCH"] == "1"))
struct RealCatalogBenchTests {
    /// The sandboxed app's container paths — `AppDirectories.standard` resolves outside the
    /// container in an unsandboxed test process, so the harness points at the container itself.
    static var containerDirectories: AppDirectories {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/app.prism.Prism/Data/Library")
        return AppDirectories(
            root: library.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: library.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
    }

    private static func ms(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: end)
        return Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    private static var rssMiB: Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    /// Process CPU seconds (user+system) — noise-robust unlike wall time on a loaded machine:
    /// competing processes inflate wall time but not the CPU time this process actually burns.
    private static var cpuSeconds: Double {
        let usage = cpuUserSystem
        return usage.user + usage.system
    }

    private static var cpuUserSystem: (user: Double, system: Double) {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return (
            Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
            Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        )
    }


    private static func expectSameCatalog(_ actual: Catalog, _ expected: Catalog) {
        #expect(actual.sources == expected.sources)
        #expect(actual.channels == expected.channels)
        #expect(actual.movies == expected.movies)
        #expect(actual.series == expected.series)
        #expect(actual.liveCategories == expected.liveCategories)
        #expect(actual.movieCategories == expected.movieCategories)
        #expect(actual.seriesCategories == expected.seriesCategories)
        #expect(actual.indexes.categories == expected.indexes.categories)
        #expect(actual.indexes.sourceIndex == expected.indexes.sourceIndex)
        #expect(actual.indexes.categoryGroups == expected.indexes.categoryGroups)
        #expect(actual.indexes.categoryToGroup == expected.indexes.categoryToGroup)
        #expect(actual.indexes.movieByTitleID == expected.indexes.movieByTitleID)
        #expect(actual.indexes.seriesByTitleID == expected.indexes.seriesByTitleID)
        #expect(actual.indexes.movieByContent == expected.indexes.movieByContent)
        #expect(actual.indexes.seriesByContent == expected.indexes.seriesByContent)
        #expect(actual.indexes.channelByContent == expected.indexes.channelByContent)
        #expect(actual.indexes.channelByGroupID == expected.indexes.channelByGroupID)
        #expect(actual.indexes.categoryLanguages == expected.indexes.categoryLanguages)
        #expect(actual.indexes.groupMembers == expected.indexes.groupMembers)
        #expect(actual.indexes.featuredMovies == expected.indexes.featuredMovies)
        #expect(actual.indexes.featuredSeries == expected.indexes.featuredSeries)
        #expect(actual.indexes.topRatedMovies == expected.indexes.topRatedMovies)
        #expect(actual.indexes.topRatedSeries == expected.indexes.topRatedSeries)
    }

    @Test func launchPipeline() async throws {
        let directories = Self.containerDirectories
        let store = SourceStore(directories: directories)
        let sources = store.load().filter(\.isEnabled)
        try #require(!sources.isEmpty)

        let clock = ContinuousClock()
        // The versioned test initializer skips the obsolete-archive purge task: the harness
        // must be strictly read-only on the user's real data.
        let catalogCache = CatalogCache(directories: directories, version: CatalogCache.formatVersion)
        let epgCache = EPGCache(directories: directories, version: EPGCache.formatVersion)

        // Phase 1: cache decode (launch path).
        var catalogs: [SourceCatalog] = []
        var decodeMS = 0.0
        for source in sources {
            let start = clock.now
            guard let catalog = await catalogCache.load(source.id) else { continue }
            decodeMS += Self.ms(start, clock.now)
            catalogs.append(catalog)
        }
        try #require(!catalogs.isEmpty)
        let channels = catalogs.reduce(0) { $0 + $1.channels.count }
        let movies = catalogs.reduce(0) { $0 + $1.movies.count }
        let series = catalogs.reduce(0) { $0 + $1.series.count }
        print("[real-bench] cache decode: \(String(format: "%.1f", decodeMS)) ms — \(channels) chaînes, \(movies) films, \(series) séries")

        // Phase 2: catalog build. CPU split alongside wall: this is the first build of the
        // process — exactly what production pays at every launch — and the user/system split
        // tells memory-stall cost (user) from kernel work (system) noise-free.
        let buildStart = clock.now
        let buildCPUStart = Self.cpuUserSystem
        let catalog = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: CatalogBuildOptions())
        let buildMS = Self.ms(buildStart, clock.now)
        let buildCPUEnd = Self.cpuUserSystem
        print("[real-bench] CatalogBuilder.build: \(String(format: "%.1f", buildMS)) ms — \(catalog.movies.count) films groupés, \(catalog.series.count) séries groupées — user \(String(format: "%.0f", (buildCPUEnd.user - buildCPUStart.user) * 1000)) ms, sys \(String(format: "%.0f", (buildCPUEnd.system - buildCPUStart.system) * 1000)) ms")

        // Derived-artifact probe. The real container is never written: compressed source-cache
        // files are copied to a temporary cache root, so `BuiltCatalogCache` follows exactly its
        // production validate → decode path (including its input fingerprint checks).
        let artifactDirectories = AppDirectories.temporary("real-artifact-bench")
        defer { try? FileManager.default.removeItem(at: artifactDirectories.caches); try? FileManager.default.removeItem(at: artifactDirectories.root) }
        do {
            for source in sources {
                try FileManager.default.copyItem(at: directories.catalogCacheFile(for: source.id), to: artifactDirectories.catalogCacheFile(for: source.id))
            }
            let artifactCache = BuiltCatalogCache(directories: artifactDirectories)
            let artifactWriteStart = clock.now
            let artifactWriteCPUStart = Self.cpuUserSystem
            await artifactCache.save(
                catalog: catalog, sources: sources, catalogs: catalogs, options: CatalogBuildOptions(),
                generation: UInt64(Date.now.timeIntervalSince1970 * 1_000_000)
            )
            let artifactWriteMS = Self.ms(artifactWriteStart, clock.now)
            let artifactWriteCPUEnd = Self.cpuUserSystem
            let artifactBytes = (try? Data(contentsOf: artifactDirectories.builtCatalogFile).count) ?? 0
            let sourceCacheBytes = try sources.reduce(0) { $0 + (try Data(contentsOf: directories.catalogCacheFile(for: $1.id), options: [.mappedIfSafe]).count) }
            print("[real-bench] artifact write: \(String(format: "%.1f", artifactWriteMS)) ms, CPU \(String(format: "%.0f", (artifactWriteCPUEnd.user + artifactWriteCPUEnd.system - artifactWriteCPUStart.user - artifactWriteCPUStart.system) * 1000)) ms, size \(String(format: "%.1f", Double(artifactBytes) / 1_048_576)) MiB vs \(String(format: "%.1f", Double(sourceCacheBytes) / 1_048_576)) MiB source caches")

            let firstArtifactStart = clock.now
            let firstArtifactCPUStart = Self.cpuUserSystem
            guard let firstArtifact = await artifactCache.load(sources: sources, options: CatalogBuildOptions()) else {
                Issue.record("real artifact did not validate/decode")
                throw CancellationError()
            }
            let firstArtifactMS = Self.ms(firstArtifactStart, clock.now)
            let firstArtifactCPUEnd = Self.cpuUserSystem
            Self.expectSameCatalog(firstArtifact, catalog)
            print("[real-bench] artifact oracle: exact Catalog equality on real catalog — first load \(String(format: "%.1f", firstArtifactMS)) ms, CPU \(String(format: "%.0f", (firstArtifactCPUEnd.user + firstArtifactCPUEnd.system - firstArtifactCPUStart.user - firstArtifactCPUStart.system) * 1000)) ms")

            var hashMS = 0.0
            for source in sources {
                guard let data = try? Data(contentsOf: directories.catalogCacheFile(for: source.id), options: [.mappedIfSafe]) else { continue }
                var best = Double.infinity
                for _ in 0..<3 {
                    let start = clock.now
                    _ = BuiltCatalogCache.contentHash(data)
                    best = min(best, Self.ms(start, clock.now))
                }
                hashMS += best
            }
            print("[real-bench] input fingerprint validation hash: \(String(format: "%.2f", hashMS)) ms for \(String(format: "%.1f", Double(sourceCacheBytes) / 1_048_576)) MiB compressed source cache")

            var artifactWall: [Double] = []
            var artifactCPU: [Double] = []
            for _ in 0..<5 {
                let start = clock.now
                let cpu = Self.cpuUserSystem
                let decoded = await artifactCache.load(sources: sources, options: CatalogBuildOptions())
                artifactWall.append(Self.ms(start, clock.now))
                let end = Self.cpuUserSystem
                artifactCPU.append((end.user + end.system - cpu.user - cpu.system) * 1000)
                try #require(decoded != nil)
            }
            var rawWall: [Double] = []
            var rawCPU: [Double] = []
            var rawDecodeWall: [Double] = []
            var rawDecodeCPU: [Double] = []
            var rebuildWall: [Double] = []
            var rebuildCPU: [Double] = []
            for _ in 0..<3 {
                let start = clock.now
                let cpu = Self.cpuUserSystem
                var decodedInputs: [SourceCatalog] = []
                for source in sources {
                    if let input = await catalogCache.load(source.id) { decodedInputs.append(input) }
                }
                let decodeEnd = clock.now
                let decodeCPUEnd = Self.cpuUserSystem
                _ = await CatalogBuilder.build(sources: sources, catalogs: decodedInputs, options: CatalogBuildOptions())
                rawWall.append(Self.ms(start, clock.now))
                let end = Self.cpuUserSystem
                rawCPU.append((end.user + end.system - cpu.user - cpu.system) * 1000)
                rawDecodeWall.append(Self.ms(start, decodeEnd))
                rawDecodeCPU.append((decodeCPUEnd.user + decodeCPUEnd.system - cpu.user - cpu.system) * 1000)
                rebuildWall.append(Self.ms(decodeEnd, clock.now))
                rebuildCPU.append((end.user + end.system - decodeCPUEnd.user - decodeCPUEnd.system) * 1000)
            }
            print("[real-bench] artifact load: min wall \(String(format: "%.1f", artifactWall.min() ?? 0)) ms, min CPU \(String(format: "%.0f", artifactCPU.min() ?? 0)) ms (\(artifactWall.map { String(format: "%.1f", $0) }.joined(separator: ", ")))")
            print("[real-bench] raw decode+build same-process A/B: min wall \(String(format: "%.1f", rawWall.min() ?? 0)) ms, min CPU \(String(format: "%.0f", rawCPU.min() ?? 0)) ms — decode min \(String(format: "%.1f", rawDecodeWall.min() ?? 0))/\(String(format: "%.0f", rawDecodeCPU.min() ?? 0)) ms, warm build min \(String(format: "%.1f", rebuildWall.min() ?? 0))/\(String(format: "%.0f", rebuildCPU.min() ?? 0)) ms")
        } catch {
            Issue.record("artifact benchmark setup failed: \(error)")
        }

        // Phase 3: editorial recommendations (launch-critical) then fallback (background).
        let editorialStart = clock.now
        let recommendations = await RecommendationBuilder.buildEditorial(for: catalog)
        let editorialMS = Self.ms(editorialStart, clock.now)
        print("[real-bench] buildEditorial: \(String(format: "%.1f", editorialMS)) ms")

        // Phase 4: curation index (first real feed gates on it).
        let curationStart = clock.now
        let curation = await CurationIndex.build(catalog: catalog, recommendations: recommendations)
        let curationMS = Self.ms(curationStart, clock.now)
        print("[real-bench] CurationIndex.build: \(String(format: "%.1f", curationMS)) ms — \(curation.movieRanking.count) films classés, \(curation.seriesRanking.count) séries classées")

        // Phase 5: search index.
        let searchStart = clock.now
        let searchIndex = await SearchIndex.build(from: catalog, recommendations: recommendations)
        let searchMS = Self.ms(searchStart, clock.now)
        print("[real-bench] SearchIndex.build: \(String(format: "%.1f", searchMS)) ms")

        // Phase 6: EPG cache decode + guide build.
        var totalPrograms = 0
        for source in sources {
            let loadStart = clock.now
            guard let entry = await epgCache.load(source.id) else { continue }
            let loadMS = Self.ms(loadStart, clock.now)
            let guideStart = clock.now
            let guide = EPGGuide(programs: entry.programs, channels: entry.channels)
            let guideMS = Self.ms(guideStart, clock.now)
            totalPrograms += entry.programs.count
            print("[real-bench] EPG: decode \(String(format: "%.1f", loadMS)) ms + guide build \(String(format: "%.1f", guideMS)) ms — \(entry.programs.count) programmes, \(guide.channelCount) chaînes")
        }

        // Phase 7: representative searches on the real index.
        let queries = ["a", "le", "film", "asterix", "titanic", "breaking bad", "les", "the mandalorian"]
        for query in queries {
            var samples: [Double] = []
            for _ in 0..<30 {
                let start = clock.now
                _ = searchIndex.search(query)
                samples.append(Self.ms(start, clock.now))
            }
            samples.sort()
            print("[real-bench] search \"\(query)\": p50 \(String(format: "%.2f", samples[samples.count / 2])) ms, p95 \(String(format: "%.2f", samples[samples.count * 95 / 100])) ms")
        }

        // Fallback completion (post-publish background work).
        let fallbackStart = clock.now
        _ = await RecommendationBuilder.completeWithFallback(recommendations, for: catalog)
        let fallbackMS = Self.ms(fallbackStart, clock.now)
        print("[real-bench] completeWithFallback: \(String(format: "%.1f", fallbackMS)) ms")

        print("[real-bench] peak RSS \(String(format: "%.0f", Self.rssMiB)) MiB — \(totalPrograms) programmes EPG au total")
    }

    /// Breakdown probe: where do cache-decode and editorial seconds actually go on real data.
    @Test func costBreakdown() async throws {
        let directories = Self.containerDirectories
        let store = SourceStore(directories: directories)
        let sources = store.load().filter(\.isEnabled)
        try #require(!sources.isEmpty)
        let clock = ContinuousClock()

        // --- Decode breakdown: decompress vs JSON parse vs interning, per segment kind.
        for source in sources {
            let url = directories.catalogCacheFile(for: source.id)
            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  let unpacked = SegmentedArchive.unpack(data), unpacked.version == 1 else { continue }
            let segments = unpacked.segments
            var byTag: [UInt8: (decompress: Double, parse: Double, intern: Double, jsonBytes: Int)] = [:]
            var seen: [UInt8: Int] = [:]
            for segment in segments.dropFirst() {
                if (seen[segment.tag] ?? 0) >= 4 { continue }
                seen[segment.tag, default: 0] += 1
                guard let json = try? (segment.payload as NSData).decompressed(using: .lzfse) as Data else { continue }
                var decompressMS = 0.0
                var parseMS = 0.0
                var internMS = 0.0
                for _ in 0..<3 {
                    let dStart = clock.now
                    _ = try? (segment.payload as NSData).decompressed(using: .lzfse) as Data
                    decompressMS += Self.ms(dStart, clock.now)
                    let pStart = clock.now
                    var movies: [Movie] = []
                    var seriesList: [Series] = []
                    var channels: [Channel] = []
                    switch segment.tag {
                    case 1: channels = (try? JSONDecoder().decode([Channel].self, from: json)) ?? []
                    case 2: movies = (try? JSONDecoder().decode([Movie].self, from: json)) ?? []
                    case 3: seriesList = (try? JSONDecoder().decode([Series].self, from: json)) ?? []
                    default: break
                    }
                    parseMS += Self.ms(pStart, clock.now)
                    let iStart = clock.now
                    switch segment.tag {
                    case 1:
                        var shared = SourceCatalog(sourceID: source.id, channels: channels)
                        shared.shareRepeatedValues()
                    case 2:
                        var shared = SourceCatalog(sourceID: source.id, movies: movies)
                        shared.shareRepeatedValues()
                    case 3:
                        var shared = SourceCatalog(sourceID: source.id, series: seriesList)
                        shared.shareRepeatedValues()
                    default: break
                    }
                    internMS += Self.ms(iStart, clock.now)
                }
                var entry = byTag[segment.tag] ?? (0, 0, 0, 0)
                entry.decompress += decompressMS / 3
                entry.parse += parseMS / 3
                entry.intern += internMS / 3
                entry.jsonBytes = json.count
                byTag[segment.tag] = entry
            }
            let totalBytes = segments.dropFirst().reduce(0) { $0 + $1.payload.count }
            for (tag, entry) in byTag.sorted(by: { $0.key < $1.key }) {
                let kind = [1: "channels", 2: "movies", 3: "series"][tag] ?? "?"
                print("[probe] decode \(kind): decompress \(String(format: "%.2f", entry.decompress)) ms + parse \(String(format: "%.2f", entry.parse)) ms + intern \(String(format: "%.2f", entry.intern)) ms par segment (~\(entry.jsonBytes / 1024) Ko JSON), \(segments.count - 1) segments, \(totalBytes / 1_048_576) Mo comprimé")
            }

            // Parallel parse-only wall time over every segment (no interning, no append),
            // batched like the real decode: the floor it could approach if overheads vanished.
            let allSegments = Array(segments.dropFirst())
            let wallStart = clock.now
            let batchSize = min(max(4, ProcessInfo.processInfo.activeProcessorCount), 10)
            for lower in stride(from: 0, to: allSegments.count, by: batchSize) {
                let batch = allSegments[lower..<min(lower + batchSize, allSegments.count)]
                await withTaskGroup(of: Void.self) { group in
                    for segment in batch {
                        group.addTask {
                            guard let json = try? (segment.payload as NSData).decompressed(using: .lzfse) as Data else { return }
                            switch segment.tag {
                            case 1: _ = try? JSONDecoder().decode([Channel].self, from: json)
                            case 2: _ = try? JSONDecoder().decode([Movie].self, from: json)
                            case 3: _ = try? JSONDecoder().decode([Series].self, from: json)
                            default: break
                            }
                        }
                    }
                }
            }
            print("[probe] parallel parse-only wall (batched \(batchSize)): \(String(format: "%.1f", Self.ms(wallStart, clock.now))) ms sur \(allSegments.count) segments")
        }

        // --- Editorial breakdown: cost of plot analysis (ProviderSynopsis) on real plots.
        let catalogCache = CatalogCache(directories: directories, version: CatalogCache.formatVersion)
        var catalogs: [SourceCatalog] = []
        for source in sources {
            if let catalog = await catalogCache.load(source.id) { catalogs.append(catalog) }
        }
        try #require(!catalogs.isEmpty)
        let catalog = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: CatalogBuildOptions())

        // Sample 30 titles with several variants (the editorial scan's real input shape).
        let sampled = catalog.movies.filter { $0.variants.count >= 3 }.prefix(30)
        var plotInputs = 0
        var plotMS = 0.0
        var audioMS = 0.0
        for title in sampled {
            let plots = [title.plot] + title.variants.prefix(12).map { $0.movie?.plot ?? $0.series?.plot }
            let pStart = clock.now
            _ = ProviderSynopsis.preferredFrenchOrEnglish(from: plots)
            plotMS += Self.ms(pStart, clock.now)
            plotInputs += 1
            let aStart = clock.now
            _ = RecommendationBuilder.availableAudio(for: title, original: nil, catalog: catalog)
            audioMS += Self.ms(aStart, clock.now)
        }
        print("[probe] preferredFrenchOrEnglish: \(String(format: "%.2f", plotMS / Double(max(plotInputs, 1)))) ms/titre (\(plotInputs) titres échantillonnés)")
        print("[probe] availableAudio: \(String(format: "%.3f", audioMS / Double(max(plotInputs, 1)))) ms/titre")

        // --- Volume breakdown: which string data dominates the decoded catalog footprint.
        var plotBytes = 0, plotCount = 0, titleBytes = 0, urlBytes = 0, castBytes = 0, genreBytes = 0
        var seriesWithSeasons = 0, seasonCount = 0, episodeCount = 0, episodePlotBytes = 0
        for source in catalogs {
            for movie in source.movies {
                plotBytes += movie.plot?.utf8.count ?? 0
                plotCount += movie.plot == nil ? 0 : 1
                titleBytes += movie.title.utf8.count + movie.rawName.utf8.count
                urlBytes += (movie.posterURL?.absoluteString.utf8.count ?? 0) + (movie.backdropURL?.absoluteString.utf8.count ?? 0)
                castBytes += movie.cast.reduce(0) { $0 + $1.utf8.count }
                genreBytes += movie.genres.reduce(0) { $0 + $1.utf8.count }
            }
            for series in source.series {
                plotBytes += series.plot?.utf8.count ?? 0
                plotCount += series.plot == nil ? 0 : 1
                titleBytes += series.title.utf8.count + series.rawName.utf8.count
                urlBytes += (series.posterURL?.absoluteString.utf8.count ?? 0) + (series.backdropURL?.absoluteString.utf8.count ?? 0)
                castBytes += series.cast.reduce(0) { $0 + $1.utf8.count }
                genreBytes += series.genres.reduce(0) { $0 + $1.utf8.count }
                if let seasons = series.seasons {
                    seriesWithSeasons += 1
                    seasonCount += seasons.count
                    for season in seasons {
                        episodeCount += season.episodes.count
                        episodePlotBytes += season.episodes.reduce(0) { $0 + ($1.plot?.utf8.count ?? 0) }
                    }
                }
            }
        }
        print("[probe] volumes — plots \(plotBytes >> 20) MiB (\(plotCount) items), titres \(titleBytes >> 20) MiB, urls \(urlBytes >> 20) MiB, cast \(castBytes >> 20) MiB, genres \(genreBytes >> 20) MiB")
        print("[probe] séries avec saisons: \(seriesWithSeasons), saisons \(seasonCount), épisodes \(episodeCount), plots épisodes \(episodePlotBytes >> 20) MiB")
    }

    /// Input-isolation probe: builds the same logical catalog decoded from the v2 binary cache
    /// and from a v1 JSON transcode of it (written to /tmp, never touching the container),
    /// alternating in one process. Tells apart input-dependent build costs (string instance
    /// sharing) from code regressions: same code, same machine noise, only the decode input differs.
    @Test func inputIsolation() async throws {
        let directories = Self.containerDirectories
        let store = SourceStore(directories: directories)
        let sources = store.load().filter(\.isEnabled)
        try #require(!sources.isEmpty)
        let clock = ContinuousClock()

        let reader = CatalogCache(directories: directories, version: CatalogCache.formatVersion)
        var v2Catalogs: [SourceCatalog] = []
        for source in sources {
            if let catalog = await reader.load(source.id) { v2Catalogs.append(catalog) }
        }
        try #require(!v2Catalogs.isEmpty)

        // Transcode to v1 JSON in /tmp (writeonly there; container data untouched).
        let tmpRoot = URL(fileURLWithPath: "/tmp/prism-input-probe", isDirectory: true)
        let tmpDirectories = AppDirectories(
            root: tmpRoot.appending(path: "root", directoryHint: .isDirectory),
            caches: tmpRoot.appending(path: "caches", directoryHint: .isDirectory)
        )
        try? FileManager.default.removeItem(at: tmpRoot)
        try FileManager.default.createDirectory(at: tmpDirectories.caches.appending(path: "Catalogs", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let v1Writer = CatalogCache(directories: tmpDirectories, version: 1)
        for catalog in v2Catalogs {
            try await v1Writer.save(catalog)
        }
        let v1Reader = CatalogCache(directories: tmpDirectories, version: 1)
        var v1Catalogs: [SourceCatalog] = []
        for source in sources {
            if let catalog = await v1Reader.load(source.id) { v1Catalogs.append(catalog) }
        }
        try #require(v1Catalogs.count == v2Catalogs.count)

        // PRISM_PROBE_PREWARM=1: allocate, touch and free ~700 MB before the first build.
        // If the first-build inflation vanishes, the cold cost is heap growth / first-touch
        // page work rather than anything the build itself does.
        if ProcessInfo.processInfo.environment["PRISM_PROBE_PREWARM"] == "1" {
            var blocks: [Data] = []
            for _ in 0..<28 {
                var block = Data(count: 25 << 20)
                block.withUnsafeMutableBytes { ptr in
                    guard let base = ptr.baseAddress else { return }
                    memset(base, 1, 25 << 20)
                }
                blocks.append(block)
            }
            blocks.removeAll()
            print("[input-probe] prewarmed 700 MB")
        }
        // Alternating builds: A/B/A/B — same process, same noise conditions. CPU-time deltas
        // include everything the build spawns (parallel grouping) since the process is otherwise
        // idle between measurements. PRISM_PROBE_V1_FIRST=1 swaps the order: the first build in
        // a process pays cold-start costs (heap growth, runtime warm-up) and order must not
        // confound the input comparison.
        let v1First = ProcessInfo.processInfo.environment["PRISM_PROBE_V1_FIRST"] == "1"
        let ordering: [(String, [SourceCatalog])] = v1First
            ? [("v1-json", v1Catalogs), ("v2-binary", v2Catalogs)]
            : [("v2-binary", v2Catalogs), ("v1-json", v1Catalogs)]
        for round in 1...2 {
            for (label, input) in ordering {
                let start = clock.now
                let cpuStart = Self.cpuUserSystem
                let catalog = await CatalogBuilder.build(sources: sources, catalogs: input, options: CatalogBuildOptions())
                let elapsed = Self.ms(start, clock.now)
                let cpuEnd = Self.cpuUserSystem
                let user = (cpuEnd.user - cpuStart.user) * 1000
                let system = (cpuEnd.system - cpuStart.system) * 1000
                print("[input-probe] round\(round) build from \(label): wall \(String(format: "%.1f", elapsed)) ms, user \(String(format: "%.0f", user)) ms, sys \(String(format: "%.0f", system)) ms — \(catalog.movies.count) films")
            }
        }
        try? FileManager.default.removeItem(at: tmpRoot)
    }
}
