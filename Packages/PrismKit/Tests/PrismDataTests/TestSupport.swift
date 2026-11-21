import Foundation
import PrismCore
@testable import PrismData

enum Fixture {
    static let a: SourceID = "src-a"
    static let b: SourceID = "src-b"
    static let c: SourceID = "src-c"

    static let reference = Date(timeIntervalSince1970: 1_750_000_000)

    static func source(_ id: SourceID, _ name: String? = nil, kind: SourceKind = .m3uURL, enabled: Bool = true) -> Source {
        Source(
            id: id, name: name ?? id.rawValue, kind: kind,
            serverURL: URL(string: "https://example.com/\(id.rawValue).m3u"),
            isEnabled: enabled, createdAt: reference
        )
    }

    static func url(_ path: String) -> URL {
        URL(string: "https://example.com/\(path)")!
    }

    static func movie(
        _ source: SourceID, _ id: String, _ title: String, year: Int? = nil, quality: VideoQuality = .unknown,
        raw: String? = nil, category: String? = nil, poster: String? = nil, backdrop: String? = nil,
        plot: String? = nil, genres: [String] = [], rating: Double? = nil, added: Date? = nil, tmdbID: Int? = nil, adult: Bool = false
    ) -> Movie {
        Movie(
            sourceID: source, nativeID: id, title: title, rawName: raw ?? title, year: year,
            posterURL: poster.map(url), backdropURL: backdrop.map(url), plot: plot, genres: genres,
            rating: rating, categoryID: category, streamURL: url("\(source.rawValue)/movie/\(id).mp4"),
            quality: quality, addedAt: added, tmdbID: tmdbID, isAdult: adult
        )
    }

    static func series(
        _ source: SourceID, _ id: String, _ title: String, year: Int? = nil, quality: VideoQuality = .unknown,
        raw: String? = nil, category: String? = nil, poster: String? = nil, plot: String? = nil,
        genres: [String] = [], rating: Double? = nil, added: Date? = nil, tmdbID: Int? = nil, seasons: [Season]? = nil
    ) -> Series {
        Series(
            sourceID: source, nativeID: id, title: title, rawName: raw ?? title, year: year,
            posterURL: poster.map(url), plot: plot, genres: genres, rating: rating, categoryID: category,
            quality: quality, addedAt: added, tmdbID: tmdbID, seasons: seasons
        )
    }

    static func seasons(series: String, source: SourceID, counts: [Int]) -> [Season] {
        let seriesID = ContentID(source: source, kind: .series, nativeID: series)
        return counts.enumerated().map { offset, count in
            let seasonNumber = offset + 1
            return Season(number: seasonNumber, episodes: (1...count).map { number in
                Episode(
                    seriesID: seriesID, sourceID: source, nativeID: "\(series)-s\(seasonNumber)e\(number)",
                    season: seasonNumber, number: number, title: "Épisode \(number)",
                    durationSeconds: 2_400, streamURL: url("\(source.rawValue)/series/\(series)/\(seasonNumber)/\(number).mkv")
                )
            })
        }
    }

    static func channel(
        _ source: SourceID, _ id: String, _ name: String, number: Int? = nil, quality: VideoQuality = .unknown,
        raw: String? = nil, category: String? = nil, epg: String? = nil, logo: String? = nil, adult: Bool = false
    ) -> Channel {
        Channel(
            sourceID: source, nativeID: id, name: name, rawName: raw ?? name, number: number,
            logoURL: logo.map(url), categoryID: category, epgID: epg,
            streamURL: url("\(source.rawValue)/live/\(id).m3u8"), quality: quality, isAdult: adult
        )
    }

    static func category(_ source: SourceID, _ kind: MediaKind, _ native: String, _ name: String, adult: Bool = false, sort: Int = 0) -> PrismCore.Category {
        PrismCore.Category(sourceID: source, kind: kind, nativeID: native, name: name, isAdult: adult, sortIndex: sort)
    }

    static func categoryID(_ source: SourceID, _ kind: MediaKind, _ native: String) -> String {
        "\(source.rawValue):\(kind.rawValue):\(native)"
    }

    static func program(_ channel: String, _ startMinutes: Int, _ endMinutes: Int, _ title: String = "Programme") -> EPGProgram {
        EPGProgram(
            channelID: channel,
            start: reference.addingTimeInterval(TimeInterval(startMinutes * 60)),
            end: reference.addingTimeInterval(TimeInterval(endMinutes * 60)),
            title: title
        )
    }

    static func build(_ sources: [Source], _ catalogs: [SourceCatalog], hideAdult: Bool = false) async -> Catalog {
        await CatalogBuilder.build(sources: sources, catalogs: catalogs, options: .init(hideAdult: hideAdult))
    }
}

/// Deterministic PRNG for synthetic data.
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Synthetic {
    static let vocabulary: [String] = {
        let syllables = ["ka", "lo", "mi", "ra", "ten", "vor", "zu", "bel", "cha", "dor", "e", "fi", "gan", "hu", "il", "jo",
                         "kel", "lum", "mor", "nar", "o", "pra", "qui", "ros", "sel", "tam", "u", "vel", "wa", "xen", "yo", "zar"]
        var rng = SplitMix64(seed: 42)
        var words: Set<String> = []
        while words.count < 6_000 {
            let count = Int.random(in: 1...3, using: &rng)
            words.insert((0..<count).map { _ in syllables.randomElement(using: &rng)! }.joined())
        }
        return words.sorted()
    }()

    static func title(_ rng: inout SplitMix64) -> String {
        let count = Int.random(in: 1...4, using: &rng)
        return (0..<count).map { _ in vocabulary.randomElement(using: &rng)!.capitalized }.joined(separator: " ")
    }

    /// `movies` / `series` / `channels` spread over 3 sources, with ~20 % cross-source duplicates.
    static func catalogs(movies: Int, series: Int, channels: Int) -> (sources: [Source], catalogs: [SourceCatalog]) {
        let ids: [SourceID] = ["syn-a", "syn-b", "syn-c"]
        var rng = SplitMix64(seed: 7)
        var catalogs = ids.map { id in
            SourceCatalog(
                sourceID: id,
                categories: (0..<40).map { Fixture.category(id, .movie, "m\($0)", "Films \($0)", sort: $0) }
                    + (0..<20).map { Fixture.category(id, .series, "s\($0)", "Séries \($0)", sort: $0) }
                    + (0..<30).map { Fixture.category(id, .live, "l\($0)", "Chaînes \($0)", sort: $0) },
                fetchedAt: Fixture.reference
            )
        }
        var recentMovies: [(String, Int)] = []
        for index in 0..<movies {
            let sourceIndex = index % 3
            let source = ids[sourceIndex]
            let (title, year): (String, Int)
            if index % 5 == 0, let previous = recentMovies.randomElement(using: &rng) {
                (title, year) = previous
            } else {
                (title, year) = (Synthetic.title(&rng), Int.random(in: 1950...2025, using: &rng))
                recentMovies.append((title, year))
                if recentMovies.count > 500 { recentMovies.removeFirst(100) }
            }
            let quality = VideoQuality(rawValue: Int.random(in: 0...4, using: &rng)) ?? .unknown
            catalogs[sourceIndex].movies.append(Movie(
                sourceID: source, nativeID: "\(index)", title: title, rawName: "FR: \(title) (\(year)) \(quality.badge ?? "")",
                year: year, posterURL: index % 2 == 0 ? Fixture.url("p/\(index).jpg") : nil,
                plot: index % 3 == 0 ? "Un film synthétique numéro \(index) avec une intrigue suffisamment longue." : nil,
                genres: ["Action", "Drame", "Comédie"].shuffled(using: &rng).prefix(2).map { $0 },
                rating: Double(Int.random(in: 0...100, using: &rng)) / 10,
                categoryID: "m\(Int.random(in: 0..<40, using: &rng))",
                streamURL: Fixture.url("\(source.rawValue)/movie/\(index).mkv"), quality: quality,
                addedAt: Fixture.reference.addingTimeInterval(-Double(Int.random(in: 0...3_000_000, using: &rng)))
            ))
        }
        for index in 0..<series {
            let sourceIndex = index % 3
            let source = ids[sourceIndex]
            let title = Synthetic.title(&rng)
            catalogs[sourceIndex].series.append(Series(
                sourceID: source, nativeID: "\(index)", title: title, year: Int.random(in: 1990...2025, using: &rng),
                posterURL: Fixture.url("s/\(index).jpg"), rating: Double(Int.random(in: 0...100, using: &rng)) / 10,
                categoryID: "s\(Int.random(in: 0..<20, using: &rng))",
                addedAt: Fixture.reference.addingTimeInterval(-Double(Int.random(in: 0...3_000_000, using: &rng)))
            ))
        }
        for index in 0..<channels {
            let sourceIndex = index % 3
            let source = ids[sourceIndex]
            let name = index % 4 == 0 ? "Chaîne \(index / 12)" : Synthetic.title(&rng)
            catalogs[sourceIndex].channels.append(Channel(
                sourceID: source, nativeID: "\(index)", name: name, rawName: "FR| \(name) HD",
                number: index % 7 == 0 ? nil : index, categoryID: "l\(Int.random(in: 0..<30, using: &rng))",
                epgID: "\(name.lowercased()).fr", streamURL: Fixture.url("\(source.rawValue)/live/\(index).ts"),
                quality: .hd
            ))
        }
        return (ids.map { Fixture.source($0) }, catalogs)
    }
}

/// Wall-clock measurement in milliseconds.
func measureMilliseconds<T>(_ body: () async throws -> T) async rethrows -> (T, Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let value = try await body()
    let elapsed = clock.now - start
    let ms = Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15
    return (value, ms)
}
