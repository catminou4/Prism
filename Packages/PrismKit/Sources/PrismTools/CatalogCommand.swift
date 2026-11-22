import Foundation
import PrismCore
import PrismData

/// `prism-tools catalog [containerDir]` — loads the cached catalogs of the installed app and prints
/// statistics plus the curated shelves, without touching the network or the user's library.
enum CatalogCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let container = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
        let directories = AppDirectories(
            root: container.appending(path: "Application Support/Prism", directoryHint: .isDirectory),
            caches: container.appending(path: "Caches/Prism", directoryHint: .isDirectory)
        )
        var exitCode: Int32 = 0
        var done = false
        Task {
            exitCode = await audit(directories)
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return exitCode
    }

    private static func audit(_ directories: AppDirectories) async -> Int32 {
        let sources = SourceStore(directories: directories).load()
        guard !sources.isEmpty else {
            print("no sources in \(directories.root.path)")
            return 1
        }
        let cache = CatalogCache(directories: directories)
        if ProcessInfo.processInfo.environment["PRISM_MEMORY"] != nil {
            print("baseline footprint \(footprint())")
            for source in sources {
                var probe = await cache.load(source.id)
                if let movies = probe?.movies { probeMovieFields(movies) }
                print("probe load footprint \(footprint()) (\(probe?.movies.count ?? 0) movies)")
                probe?.movies = []
                print("  without movies \(footprint())")
                probe?.channels = []
                print("  without channels \(footprint())")
                probe = nil
                print("  released \(footprint())")
            }
        }
        var catalogs: [SourceCatalog] = []
        for source in sources {
            let start = Date()
            guard let catalog = await cache.load(source.id) else { continue }
            print("loaded \(source.kind.rawValue) source: \(catalog.channels.count) channels, \(catalog.movies.count) movies, \(catalog.series.count) series in \(ms(since: start)) — footprint \(footprint())")
            if ProcessInfo.processInfo.environment["PRISM_MEMORY"] != nil {
                printMemoryStats(catalog)
                let released = malloc_zone_pressure_relief(nil, 0)
                print("pressure relief released \(released / 1_048_576) MB — footprint \(footprint())")
            }
            catalogs.append(catalog)
        }
        var start = Date()
        let catalog = await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: .init(hideAdult: true))
        print("built catalog in \(ms(since: start)): \(catalog.movies.count) movies, \(catalog.series.count) series, \(catalog.channels.count) channels — footprint \(footprint())")

        for (label, titles) in [("movies", catalog.movies), ("series", catalog.series)] {
            let total = Double(max(1, titles.count))
            func pct(_ predicate: (MediaTitle) -> Bool) -> String {
                String(format: "%.0f%%", Double(titles.count(where: predicate)) / total * 100)
            }
            print("\n\(label): \(titles.count)")
            print("  poster \(pct { $0.posterURL != nil })  backdrop \(pct { $0.backdropURL != nil })  plot \(pct { $0.plot?.isEmpty == false })")
            print("  rating \(pct { $0.rating != nil })  year \(pct { $0.year != nil })  genres \(pct { !$0.genres.isEmpty })")
            print("  tmdb \(pct { $0.variants.contains { ($0.movie?.tmdbID ?? $0.series?.tmdbID ?? 0) > 0 } })  addedAt \(pct { $0.addedAt != nil })  multi-variant \(pct { $0.variants.count > 1 })")
            var genres: [String: Int] = [:]
            for title in titles { for genre in title.genres { genres[genre, default: 0] += 1 } }
            print("  top genres: " + genres.sorted { $0.value > $1.value }.prefix(18).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            var years: [Int: Int] = [:]
            for title in titles { if let year = title.year { years[year, default: 0] += 1 } }
            print("  years: " + years.sorted { $0.key > $1.key }.prefix(8).map { "\($0.key):\($0.value)" }.joined(separator: " "))
            var ratings: [Int: Int] = [:]
            for title in titles { if let rating = title.rating { ratings[Int(rating.rounded(.down)), default: 0] += 1 } }
            print("  ratings: " + ratings.sorted { $0.key > $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        }
        for kind in [MediaKind.movie, .series] {
            let groups = catalog.categoryGroups(kind)
            print("\n\(kind.rawValue) categories (\(groups.count)): " + groups.prefix(60).map { "\($0.name) [\($0.itemCount)]" }.joined(separator: " · "))
        }
        print("\nlive categories (\(catalog.liveCategories.count)): " + catalog.liveCategories.prefix(40).map { "\($0.name) [\($0.itemCount)]" }.joined(separator: " · "))

        start = Date()
        let recommendations = await RecommendationBuilder.build(for: catalog)
        print("\nrecommendations in \(ms(since: start)) — footprint \(footprint())")
        let selection = recommendations.selection(for: HomeAudioLanguage.defaults)
        for (label, titles) in [
            ("highlights", selection.highlights), ("french", selection.french), ("american", selection.american),
            ("discoveries", selection.discoveries), ("wellRated", selection.wellRated),
        ] {
            print("  \(label) (\(titles.count)): " + titles.prefix(12).map(describe).joined(separator: " | "))
        }
        if ProcessInfo.processInfo.environment["PRISM_DUMP"] != nil { dumpCategories(catalog) }
        if ProcessInfo.processInfo.environment["PRISM_ARTWORK"] != nil { printArtworkStats(catalog) }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "\nmax RSS %.0f MB", Double(usage.ru_maxrss) / 1_048_576))
        if ProcessInfo.processInfo.environment["PRISM_CURATION"] != nil {
            await printCuration(catalog: catalog, recommendations: recommendations)
        }
        return 0
    }

    static func describe(_ title: MediaTitle) -> String {
        "\(title.title)\(title.year.map { " (\($0))" } ?? "")\(title.rating.map { String(format: " ★%.1f", $0) } ?? "")"
    }

    /// Physical footprint (what Activity Monitor shows as Memory).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    static func footprint() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? String(format: "%.0f MB", Double(info.phys_footprint) / 1_048_576) : "?"
    }

    static func ms(since start: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(start) * 1000)
    }
}

extension CatalogCommand {
    static func printCuration(catalog: Catalog, recommendations: Recommendations) async {
        var start = Date()
        let index = await CurationIndex.build(catalog: catalog, recommendations: recommendations)
        print("\ncuration index in \(ms(since: start)): \(index.isEmpty ? "empty" : "ready")")
        let profile: CurationProfile
        if let raw = ProcessInfo.processInfo.environment["PRISM_PROFILE"] {
            let ids = raw.split(separator: ",").compactMap { name -> TitleID? in
                catalog.movies.first { $0.title.localizedCaseInsensitiveContains(name) }?.id
                    ?? catalog.series.first { $0.title.localizedCaseInsensitiveContains(name) }?.id
            }
            profile = CurationProfile(watched: ids)
            print("profile: " + ids.compactMap { catalog.title($0) }.map(describe).joined(separator: ", "))
        } else {
            profile = CurationProfile()
        }
        for scope in [CurationScope.home, .movies, .series] {
            start = Date()
            let feed = await Curator.feed(
                scope: scope, catalog: catalog, index: index, recommendations: recommendations,
                languages: HomeAudioLanguage.defaults, profile: profile
            )
            print("\n=== \(scope.rawValue) feed in \(ms(since: start))")
            print("hero: " + feed.highlights.map { "[\($0.label ?? "-")] \(describe($0.title))" }.joined(separator: " | "))
            for shelf in feed.shelves {
                print("• \(shelf.title) (\(shelf.items.count)): " + shelf.items.prefix(10).map(describe).joined(separator: " | "))
            }
            print("genres: " + feed.genres.map { "\($0.genre.label) \($0.count)" }.joined(separator: ", "))
        }
    }
}
