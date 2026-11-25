import Foundation
import PrismCore

/// Lazily loaded movie / series details (Xtream `get_vod_info` / `get_series_info`), cached in memory
/// and on disk (3 days). M3U sources build details from the catalog fields.
public actor DetailRepository {
    public nonisolated let directories: AppDirectories
    nonisolated let credentials: any CredentialStoring
    nonisolated let session: URLSession
    public static let timeToLive: TimeInterval = 3 * 86_400

    /// In-memory entries kept per kind; older ones are evicted (a `SeriesDetail` holds every
    /// season and episode, so unbounded caches grow fast while browsing).
    public static let memoryLimit = 200

    private var movies = BoundedCache<ContentID, MovieDetail>(limit: DetailRepository.memoryLimit)
    private var series = BoundedCache<ContentID, SeriesDetail>(limit: DetailRepository.memoryLimit)
    private var movieTasks: [ContentID: Task<MovieDetail, any Error>] = [:]
    private var seriesTasks: [ContentID: Task<SeriesDetail, any Error>] = [:]

    public init(directories: AppDirectories, credentials: any CredentialStoring, session: URLSession = PrismURLSession.shared) {
        self.directories = directories
        self.credentials = credentials
        self.session = session
        // Detail files older than the TTL can never be served fresh: drop them once at launch.
        let directory = directories.detailCacheDirectory
        Task.detached(priority: .utility) {
            AppDirectories.purgeExpiredFiles(in: directory, ttl: Self.timeToLive)
        }
    }

    private struct Stored<Value: Codable & Sendable>: Codable {
        var savedAt: Date
        var value: Value
    }

    public func movieDetail(_ movie: Movie, source: Source) async throws -> MovieDetail {
        guard source.kind == .xtream, !DemoContent.isDemo(source) else { return Self.localDetail(movie) }
        if let cached = movies.value(for: movie.id) { return cached }
        if let fresh: MovieDetail = await read("movie", movie.id, allowStale: false) {
            movies.insert(fresh, for: movie.id)
            return fresh
        }
        if let running = movieTasks[movie.id] { return try await running.value }
        let client = try makeClient(source)
        let task = Task { Self.complete(try await client.movieDetail(movie), with: movie) }
        movieTasks[movie.id] = task
        defer { movieTasks[movie.id] = nil }
        do {
            let detail = try await task.value
            movies.insert(detail, for: movie.id)
            await write(detail, kind: "movie", id: movie.id)
            return detail
        } catch {
            if let stale: MovieDetail = await read("movie", movie.id, allowStale: true) { return stale }
            throw error
        }
    }

    public func seriesDetail(_ value: Series, source: Source) async throws -> SeriesDetail {
        guard source.kind == .xtream, !DemoContent.isDemo(source) else { return Self.localDetail(value) }
        if let cached = series.value(for: value.id) { return cached }
        if let fresh: SeriesDetail = await read("series", value.id, allowStale: false) {
            series.insert(fresh, for: value.id)
            return fresh
        }
        if let running = seriesTasks[value.id] { return try await running.value }
        let client = try makeClient(source)
        let task = Task { try await client.seriesDetail(value) }
        seriesTasks[value.id] = task
        defer { seriesTasks[value.id] = nil }
        do {
            let detail = try await task.value
            series.insert(detail, for: value.id)
            await write(detail, kind: "series", id: value.id)
            return detail
        } catch {
            if let stale: SeriesDetail = await read("series", value.id, allowStale: true) { return stale }
            throw error
        }
    }

    /// Reads the inventory already used by the detail screen or the edition picker.
    /// Opening the player does not start a separate provider request.
    public func cachedSeriesDetail(_ value: Series, source: Source) async -> SeriesDetail? {
        guard source.kind == .xtream, !DemoContent.isDemo(source) else { return Self.localDetail(value) }
        if let cached = series.value(for: value.id) { return cached }
        if let running = seriesTasks[value.id], let detail = try? await running.value { return detail }
        return await read("series", value.id, allowStale: true)
    }

    /// Empties the memory cache (disk entries expire on their own).
    public func clearMemory() {
        movies.removeAll()
        series.removeAll()
    }

    // MARK: - Local details

    static func localDetail(_ movie: Movie) -> MovieDetail {
        MovieDetail(
            movieID: movie.id, plot: movie.plot, cast: movie.cast, director: movie.director, genres: movie.genres,
            backdropURLs: movie.backdropURL.map { [$0] } ?? [], durationSeconds: movie.durationSeconds,
            releaseDate: movie.year.flatMap { Calendar(identifier: .gregorian).date(from: DateComponents(year: $0, month: 1, day: 1)) },
            rating: movie.rating, trailerURL: movie.trailerURL, tmdbID: movie.tmdbID
        )
    }

    static func localDetail(_ series: Series) -> SeriesDetail {
        SeriesDetail(
            seriesID: series.id, plot: series.plot, cast: series.cast, director: series.director, genres: series.genres,
            backdropURLs: series.backdropURL.map { [$0] } ?? [],
            releaseDate: series.year.flatMap { Calendar(identifier: .gregorian).date(from: DateComponents(year: $0, month: 1, day: 1)) },
            rating: series.rating, trailerURL: series.trailerURL,
            seasons: (series.seasons ?? []).sorted { $0.number < $1.number }, tmdbID: series.tmdbID
        )
    }

    /// Fills gaps of a server detail with what the catalog already knows.
    static func complete(_ detail: MovieDetail, with movie: Movie) -> MovieDetail {
        var result = detail
        if result.plot?.isEmpty ?? true { result.plot = movie.plot }
        if result.cast.isEmpty { result.cast = movie.cast }
        if result.director?.isEmpty ?? true { result.director = movie.director }
        if result.genres.isEmpty { result.genres = movie.genres }
        if result.backdropURLs.isEmpty, let backdrop = movie.backdropURL { result.backdropURLs = [backdrop] }
        if result.durationSeconds == nil { result.durationSeconds = movie.durationSeconds }
        if result.rating == nil { result.rating = movie.rating }
        if result.trailerURL == nil { result.trailerURL = movie.trailerURL }
        if result.tmdbID == nil { result.tmdbID = movie.tmdbID }
        return result
    }

    // MARK: - Disk cache

    private func makeClient(_ source: Source) throws -> XtreamClient {
        guard let serverText = source.serverURL?.absoluteString, let server = XtreamCredentials.normalizeServer(serverText),
              let username = source.username, !username.isEmpty,
              let password = credentials.password(for: source.id), !password.isEmpty else { throw SourceError.missingCredentials }
        return XtreamClient(
            credentials: XtreamCredentials(server: server, username: username, password: password),
            sourceID: source.id, userAgent: source.userAgent, session: session
        )
    }

    private nonisolated func file(_ kind: String, _ id: ContentID) -> URL {
        directories.detailCacheDirectory.appending(path: "\(kind)-\(SafeFileName.make(id.rawValue)).json", directoryHint: .notDirectory)
    }

    /// Shared coders: configured once, never mutated afterwards — JSON coders are thread-safe
    /// for concurrent encode/decode once their configuration is frozen, so a `static let`
    /// avoids allocating a fresh one (with its iso8601 date strategy) on every disk access.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Disk IO runs off the actor: a synchronous `Data(contentsOf:)` + decode used to block it
    /// for milliseconds on every detail open.
    @concurrent
    private nonisolated func read<Value: Codable & Sendable>(_ kind: String, _ id: ContentID, allowStale: Bool) async -> Value? {
        guard let data = try? Data(contentsOf: file(kind, id)) else { return nil }
        guard let stored = try? Self.decoder.decode(Stored<Value>.self, from: data) else { return nil }
        if !allowStale && Date.now.timeIntervalSince(stored.savedAt) > Self.timeToLive { return nil }
        return stored.value
    }

    @concurrent
    private nonisolated func write<Value: Codable & Sendable>(_ value: Value, kind: String, id: ContentID) async {
        guard let data = try? Self.encoder.encode(Stored(savedAt: .now, value: value)) else { return }
        try? data.write(to: file(kind, id), options: [.atomic])
    }
}

/// Insertion-ordered LRU cache: reads and writes mark the key as most recently used, and the
/// oldest entries are dropped past `limit`. Bounds repository memory caches.
struct BoundedCache<Key: Hashable, Value> {
    private(set) var values: [Key: Value] = [:]
    private var order: [Key] = []
    let limit: Int

    init(limit: Int) { self.limit = limit }

    var count: Int { values.count }

    /// Returns the value and marks it as recently used.
    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    /// Stores `value`, marks it as most recently used and evicts the oldest entries.
    mutating func insert(_ value: Value, for key: Key) {
        if values[key] == nil {
            order.append(key)
        } else {
            touch(key)
        }
        values[key] = value
        while order.count > limit {
            values.removeValue(forKey: order.removeFirst())
        }
    }

    mutating func removeAll() {
        values.removeAll()
        order.removeAll()
    }

    private mutating func touch(_ key: Key) {
        guard let index = order.firstIndex(of: key) else { return }
        order.remove(at: index)
        order.append(key)
    }
}
