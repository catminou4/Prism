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

        // Phase 2: catalog build.
        let buildStart = clock.now
        let catalog = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: CatalogBuildOptions())
        let buildMS = Self.ms(buildStart, clock.now)
        print("[real-bench] CatalogBuilder.build: \(String(format: "%.1f", buildMS)) ms — \(catalog.movies.count) films groupés, \(catalog.series.count) séries groupées")

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
                  let segments = SegmentedArchive.unpack(data, version: CatalogCache.formatVersion) else { continue }
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
    }
}
