import Foundation

public struct TMDBImageSet: Sendable, Hashable {
    public var backdropURL: URL?
    public var logoURL: URL?
    public var posterURL: URL?

    public init(backdropURL: URL? = nil, logoURL: URL? = nil, posterURL: URL? = nil) {
        self.backdropURL = backdropURL
        self.logoURL = logoURL
        self.posterURL = posterURL
    }
}

/// One work from a TMDB weekly chart, in the order delivered by the service.
public struct TMDBTrend: Sendable, Hashable {
    public let id: Int
    public let title: String
    public let originalTitle: String?
    public let year: Int?
    public let originalLanguage: HomeAudioLanguage?
    public let overview: String?
    public let images: TMDBImageSet

    public init(
        id: Int, title: String, originalTitle: String? = nil, year: Int? = nil,
        originalLanguage: HomeAudioLanguage? = nil, overview: String? = nil, images: TMDBImageSet = .init()
    ) {
        self.id = id
        self.title = title
        self.originalTitle = originalTitle
        self.year = year
        self.originalLanguage = originalLanguage
        self.overview = overview
        self.images = images
    }
}

public struct TMDBPerson: Sendable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var role: String?
    public var profileURL: URL?

    public init(id: Int, name: String, role: String? = nil, profileURL: URL? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.profileURL = profileURL
    }
}

public struct TMDBMetadata: Sendable, Hashable {
    public var tmdbID: Int
    public var kind: MediaKind
    public var title: String
    public var overview: String?
    public var images: TMDBImageSet
    public var cast: [TMDBPerson]
    public var directors: [String]
    public var genres: [String]
    public var runtimeMinutes: Int?
    public var releaseYear: Int?
    public var voteAverage: Double?
    public var trailerURL: URL?
    public var certification: String?

    public init(
        tmdbID: Int, kind: MediaKind, title: String, overview: String? = nil, images: TMDBImageSet = TMDBImageSet(),
        cast: [TMDBPerson] = [], directors: [String] = [], genres: [String] = [], runtimeMinutes: Int? = nil,
        releaseYear: Int? = nil, voteAverage: Double? = nil, trailerURL: URL? = nil, certification: String? = nil
    ) {
        self.tmdbID = tmdbID
        self.kind = kind
        self.title = title
        self.overview = overview
        self.images = images
        self.cast = cast
        self.directors = directors
        self.genres = genres
        self.runtimeMinutes = runtimeMinutes
        self.releaseYear = releaseYear
        self.voteAverage = voteAverage
        self.trailerURL = trailerURL
        self.certification = certification
    }
}

public struct TMDBEpisodeInfo: Sendable, Hashable {
    public var season: Int
    public var number: Int
    public var title: String?
    public var overview: String?
    public var stillURL: URL?
    public var runtimeMinutes: Int?
    public var voteAverage: Double?
    public var voteCount: Int?

    public init(
        season: Int, number: Int, title: String? = nil, overview: String? = nil, stillURL: URL? = nil,
        runtimeMinutes: Int? = nil, voteAverage: Double? = nil, voteCount: Int? = nil
    ) {
        self.season = season
        self.number = number
        self.title = title
        self.overview = overview
        self.stillURL = stillURL
        self.runtimeMinutes = runtimeMinutes
        self.voteAverage = voteAverage
        self.voteCount = voteCount
    }
}

public enum TMDBError: Error, LocalizedError, Equatable {
    case invalidCredential
    case unauthorized
    case http(Int)
    case decoding(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredential: "Clé TMDB invalide."
        case .unauthorized: "Clé TMDB refusée."
        case .http(let code): "TMDB a répondu avec une erreur (HTTP \(code))."
        case .decoding: "Réponse TMDB illisible."
        case .network(let message): "Connexion à TMDB impossible : \(message)"
        }
    }
}

/// Optional metadata enrichment (artwork, logo, cast, trailer…) from The Movie Database.
public actor TMDBClient {
    enum Auth: Equatable {
        case apiKey(String)
        case bearer(String)
    }

    static let apiBase = "https://api.themoviedb.org/3"

    let auth: Auth?
    public nonisolated let language: String
    private let http: HTTPClient
    /// Bounded LRU: stamps refresh on hit; past the cap the oldest half is evicted.
    private var cache: [String: Entry] = [:]
    private var cacheClock: UInt64 = 0

    private struct Entry {
        var metadata: TMDBMetadata
        var stamp: UInt64
    }

    private static let cacheLimit = 500

    /// `credential` is either a v3 API key (32 hex chars → `api_key=` query) or a v4 read access
    /// token (JWT → `Authorization: Bearer`).
    public init(credential: String, language: String = "fr-FR", session: URLSession? = nil) {
        auth = Self.auth(for: credential)
        self.language = language
        http = HTTPClient(session: session ?? PrismURLSession.shared, userAgent: nil)
    }

    static func auth(for credential: String) -> Auth? {
        let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count == 32, trimmed.allSatisfy(\.isHexDigit) { return .apiKey(trimmed) }
        let bare = trimmed.lowercased().hasPrefix("bearer ") ? String(trimmed.dropFirst(7)) : trimmed
        return .bearer(bare.trimmingCharacters(in: .whitespaces))
    }

    /// https://image.tmdb.org/t/p/{size}{path}
    public static func imageURL(path: String?, size: String) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespaces), !path.isEmpty else { return nil }
        let normalized = path.hasPrefix("/") ? path : "/" + path
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(normalized)")
    }

    /// Search (with year, then without) → details with images, credits, videos and certifications.
    /// Returns nil when nothing matches (or `kind` is `.live`).
    public func metadata(kind: MediaKind, title: String, year: Int?, tmdbID: Int?) async throws -> TMDBMetadata? {
        let type: TMDBMediaType
        switch kind {
        case .movie: type = .movie
        case .series, .episode: type = .tv
        case .live: return nil
        }
        var id = tmdbID.flatMap { $0 > 0 ? $0 : nil }
        if id == nil {
            let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { return nil }
            if let year {
                let hits = try await search(type, query: query, year: year)
                id = Self.bestMatch(hits, title: query, year: year)?.id
            }
            if id == nil {
                let hits = try await search(type, query: query, year: nil)
                id = Self.bestMatch(hits, title: query, year: year)?.id
            }
        }
        guard let id else { return nil }
        let cacheKey = "\(type.rawValue):\(id)"
        if let cached = cache[cacheKey] {
            cache[cacheKey]?.stamp = cacheStamp()
            return cached.metadata
        }
        let append = type == .movie ? "images,credits,videos,release_dates" : "images,credits,videos,content_ratings"
        guard let data = try await get("/\(type.rawValue)/\(id)", query: [
            ("language", language),
            ("append_to_response", append),
            ("include_image_language", "\(languageCode),en,null"),
            ("include_video_language", "\(languageCode),en"),
        ]) else { return nil }
        let metadata = try Self.decodeMetadata(data, kind: kind == .movie ? .movie : .series, region: region)
        cache[cacheKey] = Entry(metadata: metadata, stamp: cacheStamp())
        if cache.count > Self.cacheLimit {
            let excess = cache.count - Self.cacheLimit / 2
            for (key, _) in cache.sorted(by: { $0.value.stamp < $1.value.stamp }).prefix(excess) {
                cache.removeValue(forKey: key)
            }
        }
        return metadata
    }

    private func cacheStamp() -> UInt64 {
        cacheClock &+= 1
        return cacheClock
    }

    public func seasonEpisodes(tmdbID: Int, season: Int) async throws -> [TMDBEpisodeInfo] {
        guard let data = try await get("/tv/\(tmdbID)/season/\(season)", query: [("language", language)]) else { return [] }
        return try Self.decodeSeason(data)
    }

    // MARK: - Networking

    /// Weekly trending results for a single kind. No catalogue data is sent to TMDB.
    public func weeklyTrending(for kind: MediaKind) async throws -> [TMDBTrend] {
        let type: TMDBMediaType
        switch kind {
        case .movie: type = .movie
        case .series: type = .tv
        case .live, .episode: return []
        }
        guard let data = try await get("/trending/\(type.rawValue)/week", query: [("language", language)]) else { return [] }
        return try Self.decodeTrends(data)
    }

    private nonisolated var languageCode: String {
        String(language.split(separator: "-").first ?? "fr").lowercased()
    }

    private nonisolated var region: String {
        let parts = language.split(separator: "-")
        return parts.count > 1 ? String(parts[1]).uppercased() : languageCode.uppercased()
    }

    private func search(_ type: TMDBMediaType, query: String, year: Int?) async throws -> [TMDBSearchHit] {
        var items: [(String, String)] = [("query", query), ("language", language), ("include_adult", "false"), ("page", "1")]
        if let year { items.append((type == .movie ? "year" : "first_air_date_year", String(year))) }
        guard let data = try await get("/search/\(type.rawValue)", query: items) else { return [] }
        return try Self.decodeSearch(data)
    }

    /// nil on 404.
    private func get(_ path: String, query: [(String, String)]) async throws -> Data? {
        guard let auth else { throw TMDBError.invalidCredential }
        var items = query
        var headers = ["Accept": "application/json"]
        switch auth {
        case .apiKey(let key): items.append(("api_key", key))
        case .bearer(let token): headers["Authorization"] = "Bearer \(token)"
        }
        let encoded = items.map { "\(XtreamURLBuilder.query($0.0))=\(XtreamURLBuilder.query($0.1))" }.joined(separator: "&")
        guard let url = URL(string: "\(Self.apiBase)\(path)?\(encoded)") else { throw TMDBError.decoding("URL invalide") }
        do {
            let (data, response) = try await http.data(for: url, headers: headers, timeout: 20, retries: 2)
            switch response.statusCode {
            case 200..<300: return data
            case 404: return nil
            case 401: throw TMDBError.unauthorized
            default: throw TMDBError.http(response.statusCode)
            }
        } catch let error as TMDBError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            throw TMDBError.network(error.localizedDescription)
        }
    }

    // MARK: - Decoding (pure, unit-tested with fixtures)

    static func json(_ data: Data) throws -> JSONObject {
        guard let value = try? LenientValue.parse(data), let object = JSONObject(value) else {
            throw TMDBError.decoding("objet JSON attendu")
        }
        return object
    }

    static func decodeSearch(_ data: Data) throws -> [TMDBSearchHit] {
        try json(data).array("results").compactMap { element in
            guard let obj = JSONObject(element), let id = obj.int("id") else { return nil }
            return TMDBSearchHit(
                id: id,
                title: obj.string("title", "name") ?? "",
                originalTitle: obj.string("original_title", "original_name"),
                year: obj.year("release_date", "first_air_date"),
                popularity: obj.double("popularity") ?? 0
            )
        }
    }

    static func decodeTrends(_ data: Data) throws -> [TMDBTrend] {
        guard let results = try json(data).value(["results"]) as? [Any] else {
            throw TMDBError.decoding("classement TMDB manquant")
        }
        var seen: Set<Int> = []
        return results.compactMap { element in
            guard let item = JSONObject(element), item.bool("adult") != true,
                  let id = item.int("id"), id > 0,
                  let title = item.string("title", "name", "original_title", "original_name"),
                  seen.insert(id).inserted else { return nil }
            return TMDBTrend(
                id: id, title: title,
                originalTitle: item.string("original_title", "original_name"),
                year: item.year("release_date", "first_air_date"),
                originalLanguage: item.string("original_language").flatMap(HomeAudioLanguage.init(rawValue:)),
                overview: item.string("overview"),
                images: TMDBImageSet(
                    backdropURL: imageURL(path: item.string("backdrop_path"), size: "w1280"),
                    posterURL: imageURL(path: item.string("poster_path"), size: "w500")
                )
            )
        }
    }

    /// Prefers an exact (folded) title match, then the release year, then TMDB's ranking.
    static func bestMatch(_ hits: [TMDBSearchHit], title: String, year: Int?) -> TMDBSearchHit? {
        guard !hits.isEmpty else { return nil }
        let key = TitleNormalizer.key(title)
        var best: (score: Int, index: Int)?
        for (index, hit) in hits.enumerated() {
            var score = 0
            if TitleNormalizer.key(hit.title) == key { score += 4 }
            if let original = hit.originalTitle, TitleNormalizer.key(original) == key { score += 3 }
            if let year, let hitYear = hit.year {
                if hitYear == year { score += 3 } else if abs(hitYear - year) == 1 { score += 1 } else { score -= 1 }
            }
            if let current = best, current.score >= score { continue }
            best = (score, index)
        }
        return best.map { hits[$0.index] }
    }

    static func decodeMetadata(_ data: Data, kind: MediaKind, region: String = "FR") throws -> TMDBMetadata {
        let obj = try json(data)
        guard let id = obj.int("id") else { throw TMDBError.decoding("id manquant") }
        let isMovie = kind == .movie
        let images = obj.object("images") ?? .empty

        // Logo: fr → en → null, SVG served as PNG.
        let logos = images.array("logos").compactMap(JSONObject.init)
        let logo = pick(logos, languages: ["fr", "en", nil]) ?? logos.first
        var logoPath = logo?.string("file_path")
        if let path = logoPath, path.lowercased().hasSuffix(".svg") { logoPath = String(path.dropLast(4)) + ".png" }

        // Backdrop: textless (null) → en → anything → main backdrop.
        let backdrops = images.array("backdrops").compactMap(JSONObject.init)
        let backdropPath = (pick(backdrops, languages: [nil, "en"]) ?? backdrops.first)?.string("file_path") ?? obj.string("backdrop_path")

        let credits = obj.object("credits") ?? .empty
        let cast = credits.array("cast").compactMap(JSONObject.init)
            .sorted { ($0.int("order") ?? .max) < ($1.int("order") ?? .max) }
            .prefix(20)
            .compactMap { person -> TMDBPerson? in
                guard let personID = person.int("id"), let name = person.string("name") else { return nil }
                return TMDBPerson(id: personID, name: name, role: person.string("character"), profileURL: imageURL(path: person.string("profile_path"), size: "w185"))
            }
        var directors: [String] = []
        if !isMovie {
            directors = obj.array("created_by").compactMap { JSONObject($0)?.string("name") }
        }
        if directors.isEmpty {
            for member in credits.array("crew").compactMap(JSONObject.init) where member.string("job") == "Director" {
                if let name = member.string("name"), !directors.contains(name) { directors.append(name) }
            }
        }

        let runtime: Int?
        if isMovie {
            runtime = obj.int("runtime")
        } else {
            let runtimes = obj.array("episode_run_time").compactMap { LenientValue.int($0) }
            runtime = runtimes.first ?? obj.object("last_episode_to_air")?.int("runtime")
        }

        let videos = (obj.object("videos") ?? .empty).array("results").compactMap(JSONObject.init)
            .filter { $0.string("site")?.lowercased() == "youtube" && $0.string("type")?.lowercased() == "trailer" && $0.string("key") != nil }
        let trailer = pick(videos, languages: ["fr", "en"]) ?? videos.first
        let trailerURL = trailer?.string("key").flatMap { URL(string: "https://www.youtube.com/watch?v=\($0)") }

        return TMDBMetadata(
            tmdbID: id,
            kind: isMovie ? .movie : .series,
            title: obj.string("title", "name", "original_title", "original_name") ?? "",
            overview: obj.string("overview"),
            images: TMDBImageSet(
                backdropURL: imageURL(path: backdropPath, size: "original"),
                logoURL: imageURL(path: logoPath, size: "w500"),
                posterURL: imageURL(path: obj.string("poster_path"), size: "w780")
            ),
            cast: Array(cast),
            directors: directors,
            genres: obj.array("genres").compactMap { JSONObject($0)?.string("name") },
            runtimeMinutes: runtime.flatMap { $0 > 0 ? $0 : nil },
            releaseYear: obj.year("release_date", "first_air_date"),
            voteAverage: obj.double("vote_average").flatMap { $0 > 0 ? $0 : nil },
            trailerURL: trailerURL,
            certification: certification(obj, isMovie: isMovie, region: region)
        )
    }

    static func decodeSeason(_ data: Data) throws -> [TMDBEpisodeInfo] {
        let obj = try json(data)
        let seasonNumber = obj.int("season_number") ?? 0
        return obj.array("episodes").compactMap { element in
            guard let ep = JSONObject(element), let number = ep.int("episode_number") else { return nil }
            return TMDBEpisodeInfo(
                season: ep.int("season_number") ?? seasonNumber,
                number: number,
                title: ep.string("name"),
                overview: ep.string("overview"),
                stillURL: imageURL(path: ep.string("still_path"), size: "w500"),
                runtimeMinutes: ep.int("runtime").flatMap { $0 > 0 ? $0 : nil },
                voteAverage: ep.double("vote_average").flatMap { $0 > 0 && $0 <= 10 ? $0 : nil },
                voteCount: ep.int("vote_count").flatMap { $0 >= 0 ? $0 : nil }
            )
        }.sorted { ($0.season, $0.number) < ($1.season, $1.number) }
    }

    /// First element whose `iso_639_1` matches the languages in order (`nil` = no language).
    private static func pick(_ items: [JSONObject], languages: [String?]) -> JSONObject? {
        for language in languages {
            if let match = items.first(where: { $0.string("iso_639_1")?.lowercased() == language }) { return match }
        }
        return nil
    }

    private static func certification(_ obj: JSONObject, isMovie: Bool, region: String) -> String? {
        let regions = region == "US" ? ["US"] : [region, "US"]
        if isMovie {
            let results = (obj.object("release_dates") ?? .empty).array("results").compactMap(JSONObject.init)
            for code in regions {
                guard let entry = results.first(where: { $0.string("iso_3166_1")?.uppercased() == code }) else { continue }
                let dates = entry.array("release_dates").compactMap(JSONObject.init)
                // Prefer the theatrical release (type 3), then any non-empty certification.
                if let theatrical = dates.first(where: { $0.int("type") == 3 && $0.string("certification") != nil })?.string("certification") {
                    return theatrical
                }
                if let any = dates.lazy.compactMap({ $0.string("certification") }).first { return any }
            }
        } else {
            let results = (obj.object("content_ratings") ?? .empty).array("results").compactMap(JSONObject.init)
            for code in regions {
                if let rating = results.first(where: { $0.string("iso_3166_1")?.uppercased() == code })?.string("rating") { return rating }
            }
        }
        return nil
    }
}

enum TMDBMediaType: String {
    case movie
    case tv
}

struct TMDBSearchHit: Sendable, Hashable {
    var id: Int
    var title: String
    var originalTitle: String?
    var year: Int?
    var popularity: Double
}
