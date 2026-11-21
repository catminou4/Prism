import Foundation
import PrismCore

/// Optional TMDB enrichment (artwork, logo, cast, trailer…), enabled when a TMDB key is stored as
/// secret `"tmdb"`. Results are cached on disk (14 days; "not found" for 1 day) and concurrent
/// identical requests are coalesced.
public actor MetadataRepository {
    public nonisolated let directories: AppDirectories
    nonisolated let credentials: any CredentialStoring
    nonisolated let session: URLSession
    public nonisolated let language: String

    public static let positiveTTL: TimeInterval = 14 * 86_400
    public static let negativeTTL: TimeInterval = 86_400

    private var client: TMDBClient?
    private var clientKey: String?
    private var memory: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<Lookup, Never>] = [:]
    private var episodeMemory: [String: [TMDBEpisodeInfo]] = [:]
    private var trendMemory: [MediaKind: TrendCache] = [:]
    private var trendTasks: [MediaKind: TrendRequest] = [:]

    private struct CacheEntry {
        var metadata: TMDBMetadata?
        var savedAt: Date
    }

    private struct TrendCache {
        let items: [TMDBTrend]
        let loadedAt: Date?
        let refreshAfter: Date
    }

    private struct TrendRequest {
        let id = UUID()
        let task: Task<[TMDBTrend]?, Never>
    }

    enum Lookup: Sendable {
        case found(TMDBMetadata)
        case notFound
        /// Network / authorization failure: not cached, retried next time.
        case failed

        var metadata: TMDBMetadata? {
            if case .found(let metadata) = self { metadata } else { nil }
        }
    }

    public init(directories: AppDirectories, credentials: any CredentialStoring, session: URLSession = PrismURLSession.shared, language: String = "fr-FR") {
        self.directories = directories
        self.credentials = credentials
        self.session = session
        self.language = language
    }

    /// Whether a TMDB key is configured.
    public var isEnabled: Bool {
        !(credentials.tmdbKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// Call when the TMDB key changes: drops the client and in-memory results.
    public func reload() {
        client = nil
        clientKey = nil
        memory.removeAll()
        episodeMemory.removeAll()
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
        clearTrends()
    }

    public func metadata(for title: MediaTitle) async -> TMDBMetadata? {
        guard title.kind == .movie || title.kind == .series, let client = currentClient() else { return nil }
        let tmdbID = title.variants.lazy.compactMap { $0.movie?.tmdbID ?? $0.series?.tmdbID }.first { $0 > 0 }
        let key = tmdbID.map { "\(title.kind.rawValue)-tmdb-\($0)" } ?? "title-\(title.id.rawValue)"

        if let entry = memory[key], Self.isFresh(entry) { return entry.metadata }
        if let entry = readDisk(key), Self.isFresh(entry) {
            memory[key] = entry
            return entry.metadata
        }
        if let running = inFlight[key] { return await running.value.metadata }

        let kind = title.kind, name = title.title, year = title.year
        let task = Task<Lookup, Never> {
            do {
                guard let result = try await client.metadata(kind: kind, title: name, year: year, tmdbID: tmdbID) else { return .notFound }
                return .found(result)
            } catch {
                return .failed
            }
        }
        inFlight[key] = task
        let lookup = await task.value
        inFlight[key] = nil
        switch lookup {
        case .found(let metadata):
            store(CacheEntry(metadata: metadata, savedAt: .now), key: key)
        case .notFound:
            store(CacheEntry(metadata: nil, savedAt: .now), key: key)
        case .failed:
            break
        }
        return lookup.metadata
    }

    private func store(_ entry: CacheEntry, key: String) {
        memory[key] = entry
        writeDisk(key, entry)
    }

    public func episodes(tmdbID: Int, season: Int) async -> [TMDBEpisodeInfo] {
        let key = "tv-\(tmdbID)-s\(season)"
        if let cached = episodeMemory[key] { return cached }
        let stored = readEpisodes(key)
        if let stored, stored.formatVersion == Self.episodeFormatVersion {
            let episodes = stored.episodes.map(\.value)
            episodeMemory[key] = episodes
            return episodes
        }
        guard let client = currentClient(),
              let episodes = try? await client.seasonEpisodes(tmdbID: tmdbID, season: season)
        else { return stored?.episodes.map(\.value) ?? [] }
        episodeMemory[key] = episodes
        writeEpisodes(key, episodes)
        return episodes
    }

    /// One shared request per chart. A transient error may reuse that week's chart for at most one day.
    public func weeklyTrending(for kind: MediaKind) async -> [TMDBTrend] {
        guard kind == .movie || kind == .series, let client = currentClient() else { return [] }
        let cached = trendMemory[kind]
        if let cached, cached.refreshAfter > .now { return cached.items }
        let request: TrendRequest
        if let pending = trendTasks[kind] {
            request = pending
        } else {
            request = TrendRequest(task: Task { try? await client.weeklyTrending(for: kind) })
            trendTasks[kind] = request
        }
        let items = await request.task.value
        guard !request.task.isCancelled else { return [] }
        // A second awaiting caller can arrive after the first has published this request.
        guard trendTasks[kind]?.id == request.id else { return trendMemory[kind]?.items ?? [] }
        trendTasks[kind] = nil
        let now = Date.now
        let entry: TrendCache
        if let items {
            entry = TrendCache(items: items, loadedAt: now, refreshAfter: now.addingTimeInterval(6 * 3_600))
        } else {
            let recent = cached?.loadedAt.map { now.timeIntervalSince($0) < 86_400 } == true
            entry = TrendCache(
                items: recent ? cached?.items ?? [] : [],
                loadedAt: recent ? cached?.loadedAt : nil, refreshAfter: now.addingTimeInterval(15 * 60)
            )
        }
        trendMemory[kind] = entry
        return entry.items
    }

    private func clearTrends() {
        for request in trendTasks.values { request.task.cancel() }
        trendTasks.removeAll()
        trendMemory.removeAll()
    }

    // MARK: - Internals

    private func currentClient() -> TMDBClient? {
        guard let key = credentials.tmdbKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            if clientKey != nil { clearTrends() }
            client = nil
            clientKey = nil
            return nil
        }
        if let client, clientKey == key { return client }
        if clientKey != key {
            memory.removeAll()
            episodeMemory.removeAll()
            clearTrends()
        }
        let created = TMDBClient(credential: key, language: language, session: session)
        client = created
        clientKey = key
        return created
    }

    private static func isFresh(_ entry: CacheEntry) -> Bool {
        let age = Date.now.timeIntervalSince(entry.savedAt)
        return age >= 0 && age < (entry.metadata == nil ? negativeTTL : positiveTTL)
    }

    // MARK: Disk

    private nonisolated func file(_ key: String) -> URL {
        directories.metadataCacheDirectory.appending(path: SafeFileName.make(key) + ".json", directoryHint: .notDirectory)
    }

    private struct StoredEntry: Codable {
        var savedAt: Date
        var language: String
        var metadata: StoredMetadata?
    }

    private func readDisk(_ key: String) -> CacheEntry? {
        guard let data = try? Data(contentsOf: file(key)),
              let stored = try? Self.decoder.decode(StoredEntry.self, from: data),
              stored.language == language else { return nil }
        return CacheEntry(metadata: stored.metadata?.value, savedAt: stored.savedAt)
    }

    private func writeDisk(_ key: String, _ entry: CacheEntry) {
        let stored = StoredEntry(savedAt: entry.savedAt, language: language, metadata: entry.metadata.map(StoredMetadata.init))
        guard let data = try? Self.encoder.encode(stored) else { return }
        try? data.write(to: file(key), options: [.atomic])
    }

    private static let episodeFormatVersion = 2

    private struct StoredEpisodes: Codable {
        var formatVersion: Int?
        var savedAt: Date
        var language: String
        var episodes: [StoredEpisode]
    }

    private func readEpisodes(_ key: String) -> StoredEpisodes? {
        guard let data = try? Data(contentsOf: file(key)),
              let stored = try? Self.decoder.decode(StoredEpisodes.self, from: data),
              stored.language == language,
              Date.now.timeIntervalSince(stored.savedAt) < Self.positiveTTL else { return nil }
        return stored
    }

    private func writeEpisodes(_ key: String, _ episodes: [TMDBEpisodeInfo]) {
        let stored = StoredEpisodes(
            formatVersion: Self.episodeFormatVersion, savedAt: .now, language: language, episodes: episodes.map(StoredEpisode.init)
        )
        guard let data = try? Self.encoder.encode(stored) else { return }
        try? data.write(to: file(key), options: [.atomic])
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

// MARK: - Codable mirrors of the TMDB models

struct StoredMetadata: Codable {
    struct Person: Codable {
        var id: Int
        var name: String
        var role: String?
        var profileURL: URL?
    }

    var tmdbID: Int
    var kind: MediaKind
    var title: String
    var overview: String?
    var backdropURL: URL?
    var logoURL: URL?
    var posterURL: URL?
    var cast: [Person]
    var directors: [String]
    var genres: [String]
    var runtimeMinutes: Int?
    var releaseYear: Int?
    var voteAverage: Double?
    var trailerURL: URL?
    var certification: String?

    init(_ value: TMDBMetadata) {
        tmdbID = value.tmdbID
        kind = value.kind
        title = value.title
        overview = value.overview
        backdropURL = value.images.backdropURL
        logoURL = value.images.logoURL
        posterURL = value.images.posterURL
        cast = value.cast.map { Person(id: $0.id, name: $0.name, role: $0.role, profileURL: $0.profileURL) }
        directors = value.directors
        genres = value.genres
        runtimeMinutes = value.runtimeMinutes
        releaseYear = value.releaseYear
        voteAverage = value.voteAverage
        trailerURL = value.trailerURL
        certification = value.certification
    }

    var value: TMDBMetadata {
        TMDBMetadata(
            tmdbID: tmdbID, kind: kind, title: title, overview: overview,
            images: TMDBImageSet(backdropURL: backdropURL, logoURL: logoURL, posterURL: posterURL),
            cast: cast.map { TMDBPerson(id: $0.id, name: $0.name, role: $0.role, profileURL: $0.profileURL) },
            directors: directors, genres: genres, runtimeMinutes: runtimeMinutes, releaseYear: releaseYear,
            voteAverage: voteAverage, trailerURL: trailerURL, certification: certification
        )
    }
}

struct StoredEpisode: Codable {
    var season: Int
    var number: Int
    var title: String?
    var overview: String?
    var stillURL: URL?
    var runtimeMinutes: Int?
    var voteAverage: Double?
    var voteCount: Int?

    init(_ value: TMDBEpisodeInfo) {
        season = value.season
        number = value.number
        title = value.title
        overview = value.overview
        stillURL = value.stillURL
        runtimeMinutes = value.runtimeMinutes
        voteAverage = value.voteAverage
        voteCount = value.voteCount
    }

    var value: TMDBEpisodeInfo {
        TMDBEpisodeInfo(
            season: season, number: number, title: title, overview: overview, stillURL: stillURL,
            runtimeMinutes: runtimeMinutes, voteAverage: voteAverage, voteCount: voteCount
        )
    }
}
