import Foundation

/// Xtream Codes `player_api.php` client. Requests run on the actor; large JSON arrays are decoded
/// here too, never on the caller's (main) actor.
public actor XtreamClient {
    public nonisolated let credentials: XtreamCredentials
    public nonisolated let sourceID: SourceID
    private let http: HTTPClient
    /// Native category IDs flagged adult, per kind (filled by `categories(_:)`).
    private var adultCategories: [MediaKind: Set<String>] = [:]
    /// In-flight `categories(_:)` fetch per kind so concurrent `adultIDs` calls share one request.
    private var adultFetches: [MediaKind: Fetch] = [:]

    private struct Fetch {
        let id = UUID()
        let task: Task<Void, Never>
    }

    public init(credentials: XtreamCredentials, sourceID: SourceID, userAgent: String? = nil, session: URLSession? = nil) {
        self.credentials = credentials
        self.sourceID = sourceID
        self.http = HTTPClient(session: session ?? PrismURLSession.shared, userAgent: userAgent)
    }

    public func authenticate() async throws -> XtreamAccount {
        let data = try await get(action: nil, timeout: 20)
        return try await decode { try XtreamDecoder.account(data, credentials: self.credentials) }
    }

    /// live/movie/series → get_live_categories / get_vod_categories / get_series_categories.
    public func categories(_ kind: MediaKind) async throws -> [Category] {
        let action: String
        switch kind {
        case .live: action = "get_live_categories"
        case .movie: action = "get_vod_categories"
        case .series, .episode: action = "get_series_categories"
        }
        let resolvedKind: MediaKind = kind == .episode ? .series : kind
        let data = try await get(action: action)
        let categories = try await decode { try XtreamDecoder.categories(data, kind: resolvedKind, sourceID: self.sourceID) }
        adultCategories[resolvedKind] = Set(categories.filter(\.isAdult).map(\.nativeID))
        return categories
    }

    /// `streamURL` = m3u8 when `preferHLS` and the account allows it (or lists no format), `alternateStreamURL` = ts.
    public func liveStreams(preferHLS: Bool, account: XtreamAccount?) async throws -> [Channel] {
        let adult = await adultIDs(.live)
        let data = try await get(action: "get_live_streams")
        return try await decode {
            try XtreamDecoder.liveStreams(
                data, sourceID: self.sourceID, credentials: self.credentials, preferHLS: preferHLS,
                allowedFormats: account?.allowedOutputFormats ?? [], adultCategoryIDs: adult
            )
        }
    }

    public func vodStreams() async throws -> [Movie] {
        let adult = await adultIDs(.movie)
        let data = try await get(action: "get_vod_streams")
        return try await decode { try XtreamDecoder.vodStreams(data, sourceID: self.sourceID, credentials: self.credentials, adultCategoryIDs: adult) }
    }

    public func series() async throws -> [Series] {
        let adult = await adultIDs(.series)
        let data = try await get(action: "get_series")
        return try await decode { try XtreamDecoder.series(data, sourceID: self.sourceID, adultCategoryIDs: adult) }
    }

    /// `get_vod_info&vod_id=`
    public func movieDetail(_ movie: Movie) async throws -> MovieDetail {
        let data = try await get(action: "get_vod_info", extra: [URLQueryItem(name: "vod_id", value: movie.nativeID)], timeout: 20)
        return try await decode { try XtreamDecoder.movieDetail(data, movie: movie) }
    }

    /// `get_series_info&series_id=`
    public func seriesDetail(_ series: Series) async throws -> SeriesDetail {
        let data = try await get(action: "get_series_info", extra: [URLQueryItem(name: "series_id", value: series.nativeID)], timeout: 20)
        return try await decode { try XtreamDecoder.seriesDetail(data, series: series, credentials: self.credentials) }
    }

    /// `get_short_epg&stream_id=&limit=` (titles/descriptions are base64).
    public func shortEPG(streamID: String, epgChannelID: String?, limit: Int) async throws -> [EPGProgram] {
        let data = try await get(
            action: "get_short_epg",
            extra: [URLQueryItem(name: "stream_id", value: streamID), URLQueryItem(name: "limit", value: String(max(limit, 1)))],
            timeout: 15
        )
        return try await decode { try XtreamDecoder.shortEPG(data, streamID: streamID, epgChannelID: epgChannelID) }
    }

    // MARK: - Private

    /// JSONSerialization + per-item normalization of large payloads must not serialize on this
    /// actor: decoding runs on the concurrent pool, with a cancellation check on both sides.
    private func decode<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }.value
    }

    private func adultIDs(_ kind: MediaKind) async -> Set<String> {
        if let cached = adultCategories[kind] { return cached }
        let fetch: Fetch
        if let running = adultFetches[kind] {
            fetch = running
        } else {
            fetch = Fetch(task: Task { _ = try? await self.categories(kind) })
            adultFetches[kind] = fetch
        }
        await fetch.task.value
        if adultFetches[kind]?.id == fetch.id { adultFetches[kind] = nil }
        return adultCategories[kind] ?? []
    }

    private func get(action: String?, extra: [URLQueryItem] = [], timeout: TimeInterval = 30) async throws -> Data {
        let url = XtreamURLBuilder.api(credentials, action: action, extra: extra)
        do {
            let (data, response) = try await http.data(for: url, timeout: timeout, retries: 2)
            switch response.statusCode {
            case 200..<300: return data
            case 401, 403: throw XtreamError.unauthorized
            default: throw XtreamError.http(response.statusCode)
            }
        } catch let error as XtreamError {
            throw error
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw CancellationError()
            case .unsupportedURL, .badURL:
                throw XtreamError.invalidServer
            case .appTransportSecurityRequiresSecureConnection:
                throw XtreamError.secureConnectionRequired
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                throw XtreamError.untrustedSecureConnection
            default:
                throw XtreamError.network(error.localizedDescription)
            }
        } catch {
            throw XtreamError.network(error.localizedDescription)
        }
    }
}
