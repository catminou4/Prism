import Foundation
import PrismCore
import PrismData

/// `prism-tools launch [containerDir]` — replays `AppModel.bootstrap`'s critical path on the
/// installed app's caches (read-only, no network, no library writes) and prints when each
/// milestone would be reached: `.ready` (catalogue published → first useful frame of Home) and
/// Home with its curated shelves, then the guide. Run it several times as separate processes:
/// every run starts cold in memory but warm in the file system cache, like a relaunch.
enum LaunchCommand {
    static func run(_ arguments: [String]) -> Int32 {
        var arguments = arguments
        let resave = arguments.first == "--resave"
        if resave { arguments.removeFirst() }
        let container = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
        let directories = AppDirectories(
            root: container.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: container.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
        var exitCode: Int32 = 0
        var done = false
        if resave, arguments.isEmpty {
            print("--resave rewrites caches: pass an explicit scratch copy of the container")
            return 2
        }
        Task {
            exitCode = resave ? await self.resave(directories) : await measure(directories)
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return exitCode
    }

    /// Rewrites each cached catalogue the way a refresh now saves it (plots cleaned once,
    /// flag persisted) — only ever on an explicit copy of the container.
    private static func resave(_ directories: AppDirectories) async -> Int32 {
        let cache = CatalogCache(directories: directories)
        for source in SourceStore(directories: directories).load() {
            guard let catalog = await cache.load(source.id) else { continue }
            let start = ContinuousClock.now
            let cleaned = await catalog.cleaningPlots()
            print("cleaned plots of \(source.id.rawValue) in \(ContinuousClock.now - start)")
            do { try await cache.save(cleaned) } catch { print("save failed: \(error)"); return 1 }
        }
        return 0
    }

    private static func measure(_ directories: AppDirectories) async -> Int32 {
        let clock = ContinuousClock()
        let start = clock.now
        func ms() -> String {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
            return String(format: "%7.0f ms (CPU %6.0f ms)", Double((clock.now - start).components.attoseconds) / 1e15
                + Double((clock.now - start).components.seconds) * 1_000, cpu)
        }

        let sources = SourceStore(directories: directories).load()
        guard !sources.isEmpty else {
            print("no sources in \(directories.root.path)")
            return 1
        }
        let cache = CatalogCache(directories: directories)
        let repository = CatalogRepository(directories: directories, credentials: InMemoryCredentialStore(), cache: cache)
        let catalogs = await repository.cachedCatalogs(for: sources)
        print("[launch] caches decoded      \(ms())  footprint \(CatalogCommand.footprint())")
        let built = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: .init(hideAdult: true))
        print("[launch] catalogue built     \(ms())  (\(built.movies.count) films, \(built.series.count) séries, \(built.channels.count) chaînes)")
        let recommendations = await RecommendationBuilder.build(for: built)
        print("[launch] READY (1re frame)   \(ms())  footprint \(CatalogCommand.footprint())")
        let index = await CurationIndex.build(catalog: built, recommendations: recommendations)
        print("[launch] curation index      \(ms())")
        let feed = await Curator.feed(
            scope: .home, catalog: built, index: index, recommendations: recommendations,
            languages: HomeAudioLanguage.defaults, profile: CurationProfile()
        )
        print("[launch] HOME READY          \(ms())  (\(feed.shelves.count) étagères, \(feed.highlights.count) hero)")
        let epg = EPGRepository(directories: directories, credentials: InMemoryCredentialStore())
        let guide = await epg.cachedGuide(for: sources)
        print("[launch] guide loaded        \(ms())  (\(guide.channelCount) chaînes EPG)")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1_000
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000
        print(String(format: "[launch] CPU %.0f ms, max RSS %.0f MB, footprint %@", cpu,
                     Double(usage.ru_maxrss) / 1_048_576, CatalogCommand.footprint()))
        return 0
    }
}
