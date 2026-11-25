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

    /// Parses the JSON off-actor, then maps the elements in parallel slices when the list
    /// is large. Per-item mapping costs ~50-130 µs (normalization, field coercion, URL building),
    /// so a 100k-item `get_vod_streams` spends ~10 s on a single core; six workers cut that to
    /// ~2 s while the other endpoints are still downloading. Output order is always preserved.
    /// Large top-level arrays (the three catalog endpoints) take the chunked path below, which
    /// also parallelizes the object-graph parse itself. `nonisolated` so the task-group workers
    /// below inherit the generic executor: actor-isolated children would run the CPU-bound
    /// `map` back on this actor.
    private nonisolated func decodeList<T: Sendable>(
        _ data: Data,
        map: @escaping @Sendable (ArraySlice<Any>) -> [T]
    ) async throws -> [T] {
        try Task.checkCancellation()
        if data.count >= Self.parallelParseMinBytes, let chunked = await parseAndMapChunked(data, map: map) {
            try Task.checkCancellation()
            return chunked
        }
        return try await parseWholeThenMap(data, map: map)
    }

    /// Single-parse decode pipeline (exact pre-chunking behavior): one `JSONSerialization`
    /// over the whole payload, then parallel per-item mapping for large element counts.
    private nonisolated func parseWholeThenMap<T: Sendable>(
        _ data: Data,
        map: @escaping @Sendable (ArraySlice<Any>) -> [T]
    ) async throws -> [T] {
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

    /// Chunked parallel decode of a large top-level JSON array. The byte-scan splitter finds
    /// every depth-1 element range in one pass; each worker then copies its share of the bytes
    /// into a `[`…`]`-wrapped fragment, parses that fragment with `JSONSerialization`, and maps
    /// its elements — so both the object-graph construction and the per-item mapping scale with
    /// the worker count, and the giant `[Any]` tree never exists as a single allocation.
    ///
    /// Returns `nil` — meaning "use the exact single-parse fallback" — for anything the scan
    /// cannot certify: non-array roots (`{}` error objects, keyed-element dictionaries, `null`,
    /// `false`), malformed structure, a fragment that fails to parse, or a decoded element count
    /// that differs from the scanned slot count. The count comparison is the malformed-input
    /// detector: valid arrays decode exactly one element per slot, while empty slots from
    /// leading/trailing/double commas decode as zero — so a mismatch means the input was never
    /// valid JSON and the fallback reproduces the original parse error.
    private nonisolated func parseAndMapChunked<T: Sendable>(
        _ data: Data,
        map: @escaping @Sendable (ArraySlice<Any>) -> [T]
    ) async -> [T]? {
        guard let payload = XtreamDecoder.payloadForParsing(data),
              let split = TopLevelArraySplitter.split(payload) else { return nil }
        let workers = min(
            Self.maxDecodeWorkers,
            ProcessInfo.processInfo.activeProcessorCount,
            max(2, (payload.count + Self.parseChunkTargetBytes - 1) / Self.parseChunkTargetBytes),
            split.elements.count
        )
        guard workers >= 2 else { return nil }
        let chunks = TopLevelArraySplitter.chunks(split, workers: workers)
        let payloadData = split.payload
        return await withTaskGroup(of: ChunkedDecode<T>?.self, returning: [T]?.self) { group in
            for (index, range) in chunks.enumerated() {
                group.addTask {
                    var fragment = Data()
                    fragment.reserveCapacity(range.count + 2)
                    fragment.append(0x5B) // [
                    fragment.append(payloadData[range])
                    fragment.append(0x5D) // ]
                    guard let parsed = try? LenientValue.parse(fragment), let array = parsed as? [Any] else { return nil }
                    return ChunkedDecode(index: index, parsedCount: array.count, mapped: map(array[...]))
                }
            }
            var collected: [ChunkedDecode<T>] = []
            collected.reserveCapacity(chunks.count)
            for await chunk in group {
                guard let chunk else {
                    group.cancelAll()
                    return nil
                }
                collected.append(chunk)
            }
            guard collected.reduce(0, { $0 + $1.parsedCount }) == split.elements.count else { return nil }
            var total = 0
            for chunk in collected { total += chunk.mapped.count }
            var result: [T] = []
            result.reserveCapacity(total)
            for chunk in collected.sorted(by: { $0.index < $1.index }) {
                result.append(contentsOf: chunk.mapped)
            }
            return result
        }
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
    /// Payloads smaller than this keep the single-parse path: scanning, fragment copies and
    /// worker startup only pay off once the serial object-graph parse dominates (a few ms/MB).
    private static let parallelParseMinBytes = 256 * 1024
    /// Target uncompressed bytes per parse worker; small lists use fewer workers so a
    /// marginally-large payload does not pay six task startups for two milliseconds of work.
    private static let parseChunkTargetBytes = 2 * 1024 * 1024

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

/// One chunk worker's output of the parallel array parse: the number of JSON elements the
/// fragment decoded (kept separately from `mapped.count`, which legitimately drops malformed
/// items) and the mapped models, tagged with the chunk index for ordered reassembly.
/// `mapped` is `Sendable` by constraint; the counts are plain values.
private struct ChunkedDecode<T: Sendable>: Sendable {
    let index: Int
    let parsedCount: Int
    let mapped: [T]
}
