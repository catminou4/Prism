import Foundation
import PrismCore

/// Lazily loaded movie / series details (Xtream `get_vod_info` / `get_series_info`), cached in memory
/// and on disk (3 days). M3U sources build details from the catalog fields.
public actor DetailRepository {
    public nonisolated let directories: AppDirectories
    nonisolated let credentials: any CredentialStoring
    nonisolated let session: URLSession
    public static let timeToLive: TimeInterval = 3 * 86_400

    private var movies: [ContentID: MovieDetail] = [:]
    private var series: [ContentID: SeriesDetail] = [:]
    private var movieTasks: [ContentID: Task<MovieDetail, any Error>] = [:]
    private var seriesTasks: [ContentID: Task<SeriesDetail, any Error>] = [:]

    public init(directories: AppDirectories, credentials: any CredentialStoring, session: URLSession = PrismURLSession.shared) {
        self.directories = directories
        self.credentials = credentials
        self.session = session
    }

    private struct Stored<Value: Codable>: Codable {
        var savedAt: Date
        var value: Value
    }

    public func movieDetail(_ movie: Movie, source: Source) async throws -> MovieDetail {
        guard source.kind == .xtream, !DemoContent.isDemo(source) else { return Self.localDetail(movie) }
        if let cached = movies[movie.id] { return cached }
        if let fresh: MovieDetail = read("movie", movie.id, allowStale: false) {
            movies[movie.id] = fresh
            return fresh
        }
        if let running = movieTasks[movie.id] { return try await running.value }
        let client = try makeClient(source)
        let task = Task { Self.complete(try await client.movieDetail(movie), with: movie) }
        movieTasks[movie.id] = task
        defer { movieTasks[movie.id] = nil }
        do {
            let detail = try await task.value
            movies[movie.id] = detail
            write(detail, kind: "movie", id: movie.id)
            return detail
        } catch {
            if let stale: MovieDetail = read("movie", movie.id, allowStale: true) { return stale }
            throw error
        }
    }

    public func seriesDetail(_ value: Series, source: Source) async throws -> SeriesDetail {
        guard source.kind == .xtream, !DemoContent.isDemo(source) else { return Self.localDetail(value) }
        if let cached = series[value.id] { return cached }
        if let fresh: SeriesDetail = read("series", value.id, allowStale: false) {
            series[value.id] = fresh
            return fresh
        }
        if let running = seriesTasks[value.id] { return try await running.value }
        let client = try makeClient(source)
        let task = Task { try await client.seriesDetail(value) }
        seriesTasks[value.id] = task
        defer { seriesTasks[value.id] = nil }
        do {
            let detail = try await task.value
            series[value.id] = detail
            write(detail, kind: "series", id: value.id)
            return detail
        } catch {
            if let stale: SeriesDetail = read("series", value.id, allowStale: true) { return stale }
            throw error
        }
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

    private nonisolated func read<Value: Codable>(_ kind: String, _ id: ContentID, allowStale: Bool) -> Value? {
        guard let data = try? Data(contentsOf: file(kind, id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let stored = try? decoder.decode(Stored<Value>.self, from: data) else { return nil }
        if !allowStale && Date.now.timeIntervalSince(stored.savedAt) > Self.timeToLive { return nil }
        return stored.value
    }

    private nonisolated func write<Value: Codable>(_ value: Value, kind: String, id: ContentID) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(savedAt: .now, value: value)) else { return }
        try? data.write(to: file(kind, id), options: [.atomic])
    }
}
