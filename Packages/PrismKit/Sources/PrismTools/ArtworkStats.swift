import Foundation
import PrismCore
import PrismData

/// `PRISM_ARTWORK=1 prism-tools catalog`: where posters and backdrops come from.
func printArtworkStats(_ catalog: Catalog) {
    for (label, urls) in [
        ("movie posters", catalog.movies.compactMap(\.posterURL)),
        ("series posters", catalog.series.compactMap(\.posterURL)),
        ("backdrops", (catalog.movies + catalog.series).compactMap(\.backdropURL)),
        ("channel logos", catalog.channels.compactMap(\.logoURL)),
    ] {
        var hosts: [String: Int] = [:]
        var tmdbSizes: [String: Int] = [:]
        var extensions: [String: Int] = [:]
        for url in urls {
            hosts[url.host() ?? "?", default: 0] += 1
            extensions[url.pathExtension.lowercased(), default: 0] += 1
            let parts = url.pathComponents
            if url.host()?.contains("tmdb") == true, let index = parts.firstIndex(of: "p"), parts.indices.contains(index + 1) {
                tmdbSizes[parts[index + 1], default: 0] += 1
            }
        }
        print("\n\(label): \(urls.count)")
        print("  hosts: " + hosts.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("  tmdb sizes: " + tmdbSizes.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("  ext: " + extensions.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", "))
        print("  samples: " + urls.prefix(3).map(\.absoluteString).joined(separator: "  "))
    }
}

/// `PRISM_MEMORY=1`: per-record layout and string sizes of a raw source catalogue.
func printMemoryStats(_ catalog: SourceCatalog) {
    print("\nstride Movie \(MemoryLayout<Movie>.stride)  Series \(MemoryLayout<Series>.stride)  Channel \(MemoryLayout<Channel>.stride)  MediaVariant \(MemoryLayout<MediaVariant>.stride)  MediaTitle \(MemoryLayout<MediaTitle>.stride)")
    func heap(_ s: String?) -> Int {
        guard let s, s.utf8.count > 15 else { return 0 }
        return (s.utf8.count + 32 + 15) / 16 * 16
    }
    var bytes: [String: Int] = [:]
    for movie in catalog.movies {
        bytes["id", default: 0] += heap(movie.id.rawValue)
        bytes["sourceID", default: 0] += heap(movie.sourceID.rawValue)
        bytes["title", default: 0] += heap(movie.title)
        bytes["rawName", default: 0] += heap(movie.rawName)
        bytes["nativeID", default: 0] += heap(movie.nativeID)
        bytes["plot", default: 0] += heap(movie.plot)
        bytes["urls", default: 0] += [movie.posterURL, movie.backdropURL, movie.trailerURL].compactMap { $0 }.count * 186 + 186
        bytes["tags", default: 0] += movie.tags.isEmpty ? 0 : 32 + movie.tags.count * 16 + movie.tags.reduce(0) { $0 + heap($1) }
        bytes["genres", default: 0] += movie.genres.isEmpty ? 0 : 32 + movie.genres.count * 16 + movie.genres.reduce(0) { $0 + heap($1) }
        bytes["cast", default: 0] += movie.cast.isEmpty ? 0 : 32 + movie.cast.count * 16 + movie.cast.reduce(0) { $0 + heap($1) }
        bytes["headers", default: 0] += movie.httpHeaders.isEmpty ? 0 : 200
        bytes["categoryID", default: 0] += heap(movie.categoryID)
    }
    bytes["inline", default: 0] += catalog.movies.count * MemoryLayout<Movie>.stride
    print("movies (\(catalog.movies.count)) estimated MB: " + bytes.sorted { $0.value > $1.value }.map { String(format: "%@ %.1f", $0.key, Double($0.value) / 1_048_576) }.joined(separator: ", "))
}

/// Decodes variants of the same movies and reports the heap each field costs (malloc bytes in use).
func probeMovieFields(_ movies: [Movie]) {
    let sample = Array(movies.prefix(50_000))
    func inUse() -> Double {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Double(stats.size_in_use)
    }
    func measure(_ label: String, _ transform: (inout Movie) -> Void) {
        let edited = sample.map { var m = $0; transform(&m); return m }
        guard let json = try? JSONEncoder().encode(edited) else { return }
        let before = inUse()
        let decoded = try? JSONDecoder().decode([Movie].self, from: json)
        let after = inUse()
        print(String(format: "  %@: %.0f bytes/movie (json %.0f bytes/movie)", label, (after - before) / Double(sample.count), Double(json.count) / Double(sample.count)))
        withExtendedLifetime(decoded) {}
    }
    print("\nmovie field probe (\(sample.count)):")
    measure("as is") { _ in }
    measure("as is again") { _ in }
    measure("no headers") { $0.httpHeaders = [:] }
    measure("no poster/backdrop/trailer") { $0.posterURL = nil; $0.backdropURL = nil; $0.trailerURL = nil }
    measure("no stream URL") { $0.streamURL = URL(string: "x:")! }
    measure("no tags/genres/cast") { $0.tags = []; $0.genres = []; $0.cast = [] }
    measure("no plot/director") { $0.plot = nil; $0.director = nil }
    var urls: [URL] = []
    let before = inUse()
    for movie in sample { if let url = URL(string: movie.streamURL.absoluteString) { urls.append(url) } }
    print(String(format: "  one URL(string:) = %.0f bytes", (inUse() - before) / Double(sample.count)))
    var strings: [String] = []
    let b2 = inUse()
    for movie in sample { strings.append(String(movie.streamURL.absoluteString.utf8)) }
    print(String(format: "  same as String = %.0f bytes (len %.0f)", (inUse() - b2) / Double(sample.count), Double(strings.reduce(0) { $0 + $1.utf8.count }) / Double(sample.count)))
    withExtendedLifetime((urls, strings)) {}
}
