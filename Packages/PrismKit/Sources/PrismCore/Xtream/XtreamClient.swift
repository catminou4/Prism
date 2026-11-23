import Foundation

/// Xtream Codes `player_api.php` client. Requests run on the actor; large JSON arrays are decoded
/// here too, never on the caller's (main) actor.
public actor XtreamClient {
    public nonisolated let credentials: XtreamCredentials
    public nonisolated let sourceID: SourceID
    private let http: HTTPClient
    /// Native category IDs flagged adult, per kind (filled by `categories(_:)`).
    private var adultCategories: [MediaKind: Set<String>] = [:]
    /// In-flight `categories(_:)` fetch per resolved kind so concurrent callers share one request.
    private var categoryFetches: [MediaKind: CategoryFetch] = [:]
    /// In-flight `adultIDs` category lookups per kind so concurrent list endpoints share one request.
    private var adultFetches: [MediaKind: Fetch] = [:]

    private struct Fetch {
        let id = UUID()
        let task: Task<Void, Never>
    }

    private struct CategoryFetch {
        let id = UUID()
        let task: Task<[Category], any Error>
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
    /// Concurrent callers share one in-flight fetch per kind (the refresh's category pass and
    /// `adultIDs` inside the list endpoints would otherwise duplicate the same request).
    public func categories(_ kind: MediaKind) async throws -> [Category] {
        let resolvedKind: MediaKind = kind == .episode ? .series : kind
        let fetch: CategoryFetch
        if let running = categoryFetches[resolvedKind] {
            fetch = running
        } else {
            fetch = CategoryFetch(task: Task { try await self.performCategories(kind) })
            categoryFetches[resolvedKind] = fetch
        }
        defer {
            if categoryFetches[resolvedKind]?.id == fetch.id { categoryFetches[resolvedKind] = nil }
        }
        return try await fetch.task.value
    }

    private func performCategories(_ kind: MediaKind) async throws -> [Category] {
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
    /// The category lookup only feeds the `isAdult` flag, so it runs concurrently with the
    /// (much longer) list download instead of serializing in front of it.
    public func liveStreams(preferHLS: Bool, account: XtreamAccount?) async throws -> [Channel] {
        async let adult = adultIDs(.live)
        let data = try await get(action: "get_live_streams", timeout: Self.listTimeout, retries: Self.listRetries)
        let resolvedAdult = await adult
        let formats = account?.allowedOutputFormats ?? []
        let credentials = self.credentials
        let sourceID = self.sourceID
        return try await decodeList(data) { items in
            XtreamDecoder.liveStreams(items, sourceID: sourceID, credentials: credentials, preferHLS: preferHLS,
                                      allowedFormats: formats, adultCategoryIDs: resolvedAdult)
        }
    }

    public func vodStreams() async throws -> [Movie] {
        async let adult = adultIDs(.movie)
        let data = try await get(action: "get_vod_streams", timeout: Self.listTimeout, retries: Self.listRetries)
        let resolvedAdult = await adult
        let credentials = self.credentials
        let sourceID = self.sourceID
        return try await decodeList(data) { items in
            XtreamDecoder.vodStreams(items, sourceID: sourceID, credentials: credentials, adultCategoryIDs: resolvedAdult)
        }
    }

    public func series() async throws -> [Series] {
        async let adult = adultIDs(.series)
        let data = try await get(action: "get_series", timeout: Self.listTimeout, retries: Self.listRetries)
        let resolvedAdult = await adult
        let sourceID = self.sourceID
        return try await decodeList(data) { items in
            XtreamDecoder.series(items, sourceID: sourceID, adultCategoryIDs: resolvedAdult)
        }
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

    /// Parses the JSON once off-actor, then maps the elements in parallel slices when the list
    /// is large. Per-item mapping costs ~50-130 µs (normalization, field coercion, URL building),
    /// so a 100k-item `get_vod_streams` spends ~10 s on a single core; six workers cut that to
    /// ~2 s while the other endpoints are still downloading. Output order is always preserved.
    /// `nonisolated` so the task-group workers below inherit the generic executor: actor-
    /// isolated children would run the CPU-bound `map` back on this actor.
    private nonisolated func decodeList<T: Sendable>(
        _ data: Data,
        map: @escaping @Sendable (ArraySlice<Any>) -> [T]
    ) async throws -> [T] {
        try Task.checkCancellation()
        let parsed = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return ParsedElements(value: try XtreamDecoder.elements(data))
        }.value
        let count = parsed.value.count
        guard count >= Self.parallelDecodeThreshold else {
            return try await Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                return map(parsed.value[...])
            }.value
        }
        let workers = min(
            Self.maxDecodeWorkers,
            ProcessInfo.processInfo.activeProcessorCount,
            (count + Self.decodeSliceTarget - 1) / Self.decodeSliceTarget
        )
        let sliceSize = (count + workers - 1) / workers
        let chunks: [(Int, [T])] = await withTaskGroup(of: (Int, [T]).self) { group in
            for worker in 0..<workers {
                let lower = worker * sliceSize
                let upper = min(lower + sliceSize, count)
                guard lower < upper else { break }
                group.addTask {
                    (worker, map(parsed.value[lower..<upper]))
                }
            }
            var collected: [(Int, [T])] = []
            collected.reserveCapacity(workers)
            for await chunk in group { collected.append(chunk) }
            return collected
        }
        try Task.checkCancellation()
        var result: [T] = []
        result.reserveCapacity(count)
        for (_, chunk) in chunks.sorted(by: { $0.0 < $1.0 }) {
            result.append(contentsOf: chunk)
        }
        return result
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

    /// The three catalog lists are single giant GETs (tens of MB): panels routinely take
    /// >30 s to emit the first byte on `get_vod_streams`, and a timed-out retry re-downloads
    /// everything. A wide timeout plus a single retry beats three stacked 30 s attempts.
    private static let listTimeout: TimeInterval = 120
    private static let listRetries = 1

    /// Below this many elements the per-item mapping is fast enough on one core.
    private static let parallelDecodeThreshold = 12_000
    /// Target elements per decode worker; combined with the worker cap this bounds slice count.
    private static let decodeSliceTarget = 8_000
    /// Hard cap: the three lists can decode at once, so per-list workers stay modest.
    private static let maxDecodeWorkers = 6

    private func get(action: String?, extra: [URLQueryItem] = [], timeout: TimeInterval = 30, retries: Int = 2) async throws -> Data {
        let url = XtreamURLBuilder.api(credentials, action: action, extra: extra)
        do {
            let (data, response) = try await http.data(for: url, timeout: timeout, retries: retries)
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

/// The JSONSerialization tree is immutable once parsed: sharing it read-only across decode
/// tasks is safe even though `[Any]` is not `Sendable`.
private struct ParsedElements: @unchecked Sendable {
    let value: [Any]
}
