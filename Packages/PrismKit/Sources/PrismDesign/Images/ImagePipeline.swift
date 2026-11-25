import CoreGraphics
import Foundation
import SwiftUI
import Synchronization

/// Shared image loader: request de-duplication, memory cache (≈ 160 MiB, byte cost), disk cache
/// (1 GB, survives relaunch), ImageIO downsampling off the main thread.
///
/// ```swift
/// let image = await ImagePipeline.shared.image(for: url, maxPixelSize: 400)
/// ```
public actor ImagePipeline {
    public static let shared = ImagePipeline()

    /// How a decoded image relates to its target size.
    public enum Fitting: Int, Sendable, Hashable {
        /// The decoded image covers the target (aspect fill).
        case fill
        /// The decoded image fits inside the target (aspect fit / max pixel size).
        case fit
        /// A backdrop must be landscape and large enough for a hero.
        case landscapeFill
        /// A standalone poster stays portrait and is displayed without cropping.
        case portraitFit

        nonisolated var fillsTarget: Bool {
            self == .fill || self == .landscapeFill
        }

        nonisolated func acceptsSource(width: CGFloat, height: CGFloat) -> Bool {
            switch self {
            case .landscapeFill:
                width >= 640 && height >= 300 && (1.30...3.25).contains(width / height)
            case .portraitFit:
                width >= 120 && height >= 180 && (0.42...0.86).contains(width / height)
            case .fill, .fit:
                true
            }
        }

        nonisolated var needsSourceDimensions: Bool {
            self == .landscapeFill || self == .portraitFit
        }
    }

    nonisolated struct Key: Hashable, Sendable {
        let url: URL
        let width: Int
        let height: Int
        let fitting: Fitting
        let blur: Int

        var target: CGSize { CGSize(width: width, height: height) }

        func showsSameArtwork(as other: Key) -> Bool {
            url == other.url && fitting == other.fitting && blur == other.blur
        }
    }

    /// A shared task with a count of interested callers (cancelled when nobody waits anymore).
    private final class InFlight<Value: Sendable> {
        let task: Task<Value, Never>
        var waiters = 0
        /// Set when the fetch was started by the background warm path: its failure cools
        /// `warmFailedRequests` only — foreground callers joining the same entry must not
        /// poison `failedRequests` through `releaseData`.
        var warmOwned = false
        init(task: Task<Value, Never>) { self.task = task }
    }

    private let memory: MemoryCache
    private let disk: ImageDiskCache
    private let decoder = ImageDecodeQueue()
    /// Average-colour sampling, bounded separately from the decode queue so a burst of
    /// category tiles can never delay artwork that is on screen. Kept small: sampling is
    /// a 12×12 draw, and only `CategoryTile` ever asks for it.
    private let sampler = ImageDecodeQueue(limit: 2)
    private lazy var session = Self.makeSession(warming: false)
    /// Background warm-ups use their own small connection pool so they never queue ahead of
    /// artwork that is on screen.
    private lazy var prefetchSession = Self.makeSession(warming: true)
    /// Consecutive-failure backoff state for one key/URL. The cooldown escalates per
    /// consecutive failure (2 min → 10 min → 30 min cap) so permanently dead IPTV artwork
    /// stops being retried every two minutes in long sessions, while a transient failure
    /// still recovers quickly. The count survives expiry (entries are only dropped by the
    /// bounded eviction or a success) and resets when a fetch of the URL succeeds — or on
    /// relaunch, the tables being in-memory.
    private struct FailureRecord {
        var expiry: ContinuousClock.Instant
        var failures: Int
    }

    private var inFlight: [Key: InFlight<CGImage?>] = [:]
    /// Encoded-bytes fetches, shared by every decode of the same URL (sharp + blurred, sizes).
    private var dataInFlight: [URL: InFlight<Data?>] = [:]
    private var failedRequests: [URL: FailureRecord] = [:]
    /// Decode-level failures (bytes arrived, thumbnail rejected/undecodable). Deterministic
    /// per key, so a card remounting during a scroll doesn't pay the decode cost again.
    /// Time-boxed like `failedRequests`: cached bytes can be replaced by a later fetch.
    private var failedDecodes: [Key: FailureRecord] = [:]
    private var averageColors: [URL: RGBA?] = [:]
    /// Byte warm-ups waiting for a slot, most recent request first.
    private var warmQueue: [ArtworkURL.Resolved] = []
    private var warmQueued: Set<URL> = []
    private var warmRunning = 0
    /// Warm-path-only failures: a background-priority timeout must not poison the
    /// foreground cooldown (`failedRequests`) for a URL that would succeed
    /// interactively. Warm enqueues check both tables.
    private var warmFailedRequests: [URL: FailureRecord] = [:]
    private static let warmConcurrency = 3

    public init(memoryCapacity: Int = 160 << 20, diskCapacity: Int = 1 << 30, diskDirectory: URL? = nil) {
        memory = MemoryCache(costLimit: memoryCapacity)
        disk = ImageDiskCache(directory: diskDirectory, capacity: diskCapacity)
    }

    private nonisolated static func makeSession(warming: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = warming ? 2 : 6
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil // the disk cache below stores the encoded bytes
        configuration.waitsForConnectivity = false
        // No session-level `Accept`: the right value depends on the host (see `download`),
        // so every request carries its own.
        if warming { configuration.networkServiceType = .background }
        // `download` drives its tasks manually: the async `URLSession` APIs bypass session
        // delegates entirely, so the 2xx/MIME/size checks and the byte cap live in the delegate.
        return URLSession(configuration: configuration, delegate: downloadDelegate, delegateQueue: nil)
    }

    // MARK: Public API

    /// Image whose longest side is at most `maxPixelSize` pixels.
    public func image(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        await image(for: url, pixelSize: CGSize(width: maxPixelSize, height: maxPixelSize), fitting: .fit)
    }

    /// Image decoded for a `pixelSize` target (pass points × display scale).
    /// `blurRadius > 0` returns a pre-blurred low-resolution version (cheap to display upscaled).
    public func image(for url: URL, pixelSize: CGSize, fitting: Fitting = .fill, blurRadius: CGFloat = 0) async -> CGImage? {
        guard let key = Self.key(url: url, pixelSize: pixelSize, fitting: fitting, blurRadius: blurRadius) else { return nil }
        return await image(for: key)
    }

    func image(for key: Key, blurredFrom source: Key? = nil) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        if let hit = memory.image(for: key) { return hit }
        if isCoolingDown(key, in: &failedDecodes) { return nil }

        let entry: InFlight<CGImage?>
        if let existing = inFlight[key] {
            entry = existing
        } else {
            entry = InFlight(task: makeTask(for: key, blurredFrom: source ?? sharpSource(for: key)))
            inFlight[key] = entry
        }
        entry.waiters += 1
        let token = ObjectIdentifier(entry)
        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { await self.release(key, token: token, finished: false) }
        }
        release(key, token: token, finished: true)
        return Task.isCancelled ? nil : result
    }

    /// Synchronous memory-cache lookup (use from `body` to avoid placeholder flashes).
    public nonisolated func cachedImage(for url: URL, pixelSize: CGSize, fitting: Fitting = .fill, blurRadius: CGFloat = 0) -> CGImage? {
        guard let key = Self.key(url: url, pixelSize: pixelSize, fitting: fitting, blurRadius: blurRadius) else { return nil }
        return cachedImage(for: key)
    }

    nonisolated func cachedImage(for key: Key) -> CGImage? { memory.image(for: key) }

    /// A 1280-wide stand-in for a TMDB `original` (hero backdrops): it arrives in a fraction of the
    /// time and is replaced as soon as the full-resolution image is decoded. `nil` when the target
    /// is already served at its final size.
    nonisolated static func previewKey(for key: Key) -> Key? {
        guard key.blur == 0, key.width > 1280,
              ArtworkURL.resolve(key.url, target: key.target, fitting: key.fitting, fillsForBlur: false).isOriginal else { return nil }
        let height = bucket(for: CGFloat(key.height) * 1280 / CGFloat(key.width))
        return Key(url: key.url, width: 1280, height: height, fitting: key.fitting, blur: 0)
    }

    /// Downloads the bytes `RemoteImage` will need for `urls` at `pixelSize` into the disk cache,
    /// without decoding them (no memory cost). Low priority, a few at a time, newest request first.
    public nonisolated func warm(_ urls: [URL], pixelSize: CGSize, fitting: Fitting = .fill) {
        guard !urls.isEmpty, let probe = Self.key(url: urls[0], pixelSize: pixelSize, fitting: fitting, blurRadius: 0) else { return }
        let target = probe.target
        Task(priority: .utility) {
            // URL → provider-URL resolution is pure parsing (~4 µs per URL): keep it off the
            // pipeline actor, which also serves on-screen `image(for:)` calls.
            var requests: [ArtworkURL.Resolved] = []
            requests.reserveCapacity(urls.count)
            for url in urls where !url.isFileURL {
                requests.append(ArtworkURL.resolve(url, target: target, fitting: fitting, fillsForBlur: false))
            }
            await self.enqueueWarm(requests)
        }
    }

    /// Kept for API compatibility: prefetching now means warming the encoded bytes
    /// (what `warm` does); there is no separate decode-level prefetch anymore.
    public nonisolated func prefetch(_ urls: [URL], maxPixelSize: CGFloat) {
        warm(urls, pixelSize: CGSize(width: maxPixelSize, height: maxPixelSize), fitting: .fit)
    }

    /// Kept for API compatibility — see `prefetch(_:maxPixelSize:)`.
    public nonisolated func prefetch(_ urls: [URL], pixelSize: CGSize) {
        warm(urls, pixelSize: pixelSize)
    }

    /// Average (vibrance-boosted) colour of the image, cached per URL.
    public func averageColor(for url: URL) async -> Color? {
        await averageRGBA(for: url)?.color
    }

    /// Average colour as plain components (for gradients/tinting maths).
    ///
    /// Sampled lazily — only `CategoryTile` ever reads this, so decodes no longer pay the
    /// 12×12 downsample draw up front. The sample reuses, in order of cost: a sharp decode
    /// of the same URL already in the memory cache (any size/fitting), a decode already in
    /// flight, or — last resort — a tiny 64 px decode whose bytes are almost always a disk
    /// hit when the artwork is on screen elsewhere. Sampling runs on a small bounded queue,
    /// never on the decode→display path.
    public func averageRGBA(for url: URL) async -> RGBA? {
        if let cached = averageColors[url] { return cached }
        if let sharp = memory.smallestSharpEntry(forURL: url) {
            return await storeSampledAverage(url, of: sharp.image)
        }
        let candidates = inFlight.compactMap { $0.key.url == url && $0.key.blur == 0 ? $0.value : nil }
        for entry in candidates {
            if let image = await entry.task.value {
                guard !Task.isCancelled else { return nil }
                return await storeSampledAverage(url, of: image)
            }
        }
        // A same-URL caller may have memoized while the in-flight ones were awaited.
        if let cached = averageColors[url] { return cached }
        guard let image = await image(for: url, maxPixelSize: 64) else { return nil }
        return await storeSampledAverage(url, of: image)
    }

    /// Bounded-queue sampling + memoization shared by every `averageRGBA` source.
    private func storeSampledAverage(_ url: URL, of image: CGImage) async -> RGBA? {
        let sampled: RGBA? = await sampler.decode { ImageDecoder.averageColor(of: image) }
        // The queue also yields nil for a cancelled wait: that nil must not be memoized —
        // the memo has no expiry and would permanently mean "no colour" for a live URL.
        guard !Task.isCancelled else { return nil }
        return storeAverageColor(url, sampled)
    }

    /// Memoizes a sampled colour (a `nil` sample is memoized too) and keeps the table bounded.
    @discardableResult
    private func storeAverageColor(_ url: URL, _ rgba: RGBA?) -> RGBA? {
        averageColors[url] = rgba
        if averageColors.count > 16_384 { averageColors.removeAll(keepingCapacity: true) }
        return rgba
    }

    /// Drops the memory cache (e.g. on memory pressure); the disk cache is kept.
    public nonisolated func purgeMemory() { memory.removeAll() }

    /// Removes every cached image (memory + disk).
    public func removeAll() {
        memory.removeAll()
        disk.removeAll()
        averageColors.removeAll()
        failedRequests.removeAll()
        failedDecodes.removeAll()
        warmFailedRequests.removeAll()
    }

    // MARK: Internals

    /// Widths/heights at or below 1024 px bucket to 16 px steps; above that the sparse ladder
    /// takes over. The old sparse ladder (…320/384/448/512/640…) rounded common card sizes up
    /// by 10–30 % in each dimension — a 2:3 poster at 304×456 px decoded at 341×512 (~26 %
    /// pixel overhead), a 16:9 wide card at 520×296 at 640×360 (~52 %). Decode time, memory
    /// occupancy and texture upload all scale with those pixels. 16 px steps keep every
    /// card within 8 px of its ideal size while still collapsing sizes that differ by a few
    /// pixels (the 8 px input quantization already collapses live-resize noise, so the finer
    /// buckets add no fragmentation for fixed-size cards, which dominate).
    private static let largePixelBuckets = [1280, 1536, 2048, 2560, 3072]

    private nonisolated static func bucket(for pixels: CGFloat) -> Int {
        let value = Int(min(4096, pixels.rounded(.up)))
        if value <= 1024 { return max(32, (value + 15) / 16 * 16) }
        for step in largePixelBuckets where value <= step {
            return step
        }
        return 4096
    }

    nonisolated static func key(url: URL, pixelSize: CGSize, fitting: Fitting, blurRadius: CGFloat) -> Key? {
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, blurRadius.isFinite,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        // Blurs are rendered at 96 px and reused at any display size.
        let blur = blurRadius > 0 ? Int(min(384, max(1, blurRadius.rounded()))) : 0
        let width = blur > 0 ? 96 : bucket(for: pixelSize.width)
        let height = blur > 0 ? 96 : bucket(for: pixelSize.height)
        return Key(url: url, width: width, height: height, fitting: fitting, blur: blur)
    }

    /// A sharp decode of the same artwork a blurred variant can derive from instead of
    /// running its own download + decode chain: already-decoded pixels in memory first
    /// (instant), then the smallest in-flight sharp decode of the same URL. `nil` when
    /// nothing qualifies — the blur then loads its own chain, as before. Cross-fitting
    /// reuse is intended: a blur cares about the artwork's pixels, not the decode crop.
    private func sharpSource(for key: Key) -> Key? {
        guard key.blur > 0 else { return nil }
        if let cached = memory.smallestSharpEntry(forURL: key.url) {
            return cached.key
        }
        var best: Key?
        var bestPixels = Int.max
        for candidate in inFlight.keys where candidate.url == key.url && candidate.blur == 0 {
            let pixels = candidate.width * candidate.height
            if pixels < bestPixels {
                best = candidate
                bestPixels = pixels
            }
        }
        return best
    }

    private func makeTask(for key: Key, blurredFrom source: Key?) -> Task<CGImage?, Never> {
        let memory = memory
        let decoder = decoder
        let blur = CGFloat(key.blur)
        let target = key.target
        return Task.detached(priority: .userInitiated) {
            var reachedDecode = false
            var image: CGImage?
            // A blur with a sharp source needs no download and no second decode of the
            // encoded bytes: the blur is drawn from the sharp pixels directly. When the
            // derivation is unavailable (sharp rejected, dead bytes), the blur falls back
            // to its own small chain below — exactly what it would do without reuse.
            if blur > 0, let source, !Task.isCancelled,
               let sharp = await self.image(for: source), !Task.isCancelled {
                reachedDecode = true
                image = await decoder.decode {
                    ImageDecoder.blurred(sharp, radius: blur * 0.25, target: target)
                }
            }
            if image == nil, !Task.isCancelled {
                if key.url.isFileURL {
                    reachedDecode = true
                    image = await decoder.decode {
                        let thumbnail = ImageDecoder.decode(fileURL: key.url, target: target, fitting: key.fitting, fillsForBlur: blur > 0)
                        return thumbnail.flatMap { blur > 0 ? ImageDecoder.blurred($0, radius: blur * 0.25) : $0 }
                    }
                } else if let data = await self.sharedData(
                    for: ArtworkURL.resolve(key.url, target: target, fitting: key.fitting, fillsForBlur: blur > 0)
                ) {
                    reachedDecode = true
                    image = await decoder.decode {
                        let thumbnail = ImageDecoder.decode(data, target: target, fitting: key.fitting, fillsForBlur: blur > 0)
                        return thumbnail.flatMap { blur > 0 ? ImageDecoder.blurred($0, radius: blur * 0.25) : $0 }
                    }
                }
            }
            // The decode queue only yields nil without running the work when the task was
            // cancelled — a live task plus a nil means the bytes were fine but the thumbnail
            // was rejected or undecodable, which repeats identically on every remount.
            if reachedDecode, image == nil, !Task.isCancelled {
                await self.noteDecodeFailure(key)
            }
            if let image, !Task.isCancelled {
                memory.insert(image, for: key)
                // No colour sampling here: only `CategoryTile` ever reads the average, so it
                // is computed lazily in `averageRGBA` — reusing this very decode through the
                // memory cache when it is asked for the same URL.
                await self.clearDecodeFailure(key)
            }
            return image
        }
    }

    /// Encoded bytes for `request`, fetched once even when several decodes need them concurrently.
    private func sharedData(for request: ArtworkURL.Resolved) async -> Data? {
        let url = request.primary
        let entry: InFlight<Data?>
        if let existing = dataInFlight[url] {
            entry = existing
        } else {
            guard !isCoolingDown(url, in: &failedRequests) else { return nil }
            let disk = disk, session = session
            entry = InFlight(task: Task.detached(priority: .userInitiated) {
                await Self.encodedData(for: request, disk: disk, session: session)
            })
            dataInFlight[url] = entry
        }
        entry.waiters += 1
        let token = ObjectIdentifier(entry)
        let data = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { await self.releaseData(url, token: token, finished: false) }
        }
        releaseData(url, token: token, finished: true, failed: data == nil)
        return data
    }

    /// `true` while `key` is inside its failure cooldown. Expired entries are left in place:
    /// their consecutive-failure count must survive the cooldown for the backoff to escalate.
    private func isCoolingDown<K: Hashable>(_ key: K, in table: inout [K: FailureRecord]) -> Bool {
        guard let record = table[key] else { return false }
        return record.expiry > ContinuousClock.now
    }

    /// Cooldown for the n-th consecutive failure: 2 min, then 10 min, then a 30 min cap.
    private nonisolated static func failureCooldown(failures: Int) -> Duration {
        switch failures {
        case ...1: .seconds(120)
        case 2: .seconds(600)
        default: .seconds(1_800)
        }
    }

    /// Records a failure for `key`, escalating the cooldown per consecutive failure. Bounded
    /// like before: expired entries go first, then the soonest-to-expire ones if the table is
    /// still full (only then is backoff state lost).
    private func noteFailure<K: Hashable>(_ table: inout [K: FailureRecord], _ key: K) {
        if table.count >= 2_048 {
            let now = ContinuousClock.now
            table = table.filter { $0.value.expiry > now }
            if table.count >= 2_048 {
                // Evict the entries closest to expiry: they are the least valuable.
                for (k, _) in table.sorted(by: { $0.value.expiry < $1.value.expiry }).prefix(128) {
                    table[k] = nil
                }
            }
        }
        let failures = (table[key]?.failures ?? 0) + 1
        table[key] = FailureRecord(
            expiry: ContinuousClock.now.advanced(by: Self.failureCooldown(failures: failures)),
            failures: failures
        )
    }

    private func noteDecodeFailure(_ key: Key) {
        noteFailure(&failedDecodes, key)
    }

    /// Decode success restarts the key's backoff — the bytes behind the URL may have been
    /// replaced, so earlier rejections must not escalate forever. Almost always a no-op.
    private func clearDecodeFailure(_ key: Key) {
        failedDecodes[key] = nil
    }

    private func releaseData(_ url: URL, token: ObjectIdentifier, finished: Bool, failed: Bool = false) {
        guard let entry = dataInFlight[url], ObjectIdentifier(entry) == token else { return }
        if finished {
            dataInFlight[url] = nil
            if failed, !entry.task.isCancelled, !entry.warmOwned {
                noteFailure(&failedRequests, url)
            }
            if !failed, !entry.task.isCancelled {
                // Bytes arrived (network or disk): the URL is alive — restart its backoff
                // in both tables. A success can only happen outside a cooldown, so these
                // removals almost always hit nothing.
                failedRequests[url] = nil
                warmFailedRequests[url] = nil
            }
            return
        }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            dataInFlight[url] = nil
        }
    }

    /// Largest encoded payload accepted. Checked on `Content-Length` before the body is read
    /// and while streaming, so a hostile or broken "image" URL can neither balloon memory nor
    /// disk beyond this. Overshooting by a few KiB between checks is harmless.
    private static let maxImageBytes = 48 << 20

    /// Attached to both sessions in `makeSession`; `download` relies on its callbacks.
    private static let downloadDelegate = ImageDownloadDelegate(limit: maxImageBytes)

    /// Disk hit, else network. Bytes are validated (status, MIME, size cap) and — when no
    /// fallback exists — stored even if undecodable, which prevents a refetch loop for dead
    /// artwork URLs. `isDecodable` gates the return value so `encodedData` falls through to
    /// the provider's own URL; the decode step downstream is the image validator.
    @concurrent private nonisolated static func encodedData(for request: ArtworkURL.Resolved, disk: ImageDiskCache, session: URLSession) async -> Data? {
        if let data = disk.data(for: request.primary) { return data }
        if request.fallbackIsLarger, let fallback = request.fallback, let data = disk.data(for: fallback) { return data }
        // Storing undecodable bytes for the primary would shadow the fallback on later
        // requests (the disk hit always wins), so only fallback-less URLs keep them.
        if let data = await download(request.primary, disk: disk, session: session, storeUndecodable: request.fallback == nil) { return data }
        guard !Task.isCancelled, let fallback = request.fallback else { return nil }
        if !request.fallbackIsLarger, let data = disk.data(for: fallback) { return data }
        return await download(fallback, disk: disk, session: session, storeUndecodable: true)
    }

    /// No WebP/AVIF from TMDB: its CDN serves WebP to any Accept naming it (q-values ignored),
    /// and ImageIO decodes WebP in software — measured on the same w342 posters, JPEG decodes
    /// ~31 % faster (2.6 vs 3.8 ms) for ~36 % more bytes. Bytes are fetched once into the
    /// disk cache; decodes repeat on every memory-cache miss. TMDB masters are always
    /// JPEG/PNG (WebP is only a negotiated re-encode), so asking its hosts for jpeg/png can
    /// never break artwork. Other providers keep the wildcard: an IPTV host may serve
    /// WebP-only artwork, and a slow decode beats a broken image.
    private nonisolated static func acceptHeader(for url: URL) -> String {
        ArtworkURL.isTMDBHost(url) ? "image/jpeg,image/png" : "image/jpeg,image/png,image/*;q=0.8"
    }

    /// Downloads through a manually driven `URLSessionDataTask`: `ImageDownloadDelegate`
    /// rejects bad statuses, non-image MIME types and oversized `Content-Length` before the
    /// body starts, then accumulates chunks with memcpy and cancels the moment the running
    /// total passes the cap. This replaces `URLSession.AsyncBytes`, whose per-byte iteration
    /// cost tens of ns per byte (~0.3–0.8 s of CPU for a 10 MB backdrop).
    @concurrent private nonisolated static func download(_ url: URL, disk: ImageDiskCache, session: URLSession, storeUndecodable: Bool) async -> Data? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        // An explicit request: the Accept header is per-host, and the request mirrors the
        // session's timeouts/cache policy because a `URLRequest`'s own values win over the
        // configuration's.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(acceptHeader(for: url), forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        let data = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                downloadDelegate.begin(task, continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        guard let data, !data.isEmpty, data.count <= maxImageBytes else { return nil }
        guard ImageDecoder.isDecodable(data) else {
            if storeUndecodable { disk.store(data, for: url) }
            return nil
        }
        disk.store(data, for: url)
        return data
    }

    /// True when `encodedData` would answer from disk without touching the network —
    /// warming such a URL is pure churn. Mirrors the lookup order in `encodedData`:
    /// the larger fallback only short-circuits the fetch when it is the preferred size.
    private func warmServedFromDisk(_ request: ArtworkURL.Resolved) -> Bool {
        disk.contains(request.primary)
            || (request.fallbackIsLarger && request.fallback.map { disk.contains($0) } ?? false)
    }

    private func enqueueWarm(_ requests: [ArtworkURL.Resolved]) {
        var fresh: [ArtworkURL.Resolved] = []
        for request in requests {
            // Bytes already on disk make the warm-up pure churn (a detached task plus a
            // ~40 µs mmap read per URL on every scroll stop).
            guard dataInFlight[request.primary] == nil,
                  !isCoolingDown(request.primary, in: &failedRequests),
                  !isCoolingDown(request.primary, in: &warmFailedRequests),
                  !warmServedFromDisk(request),
                  warmQueued.insert(request.primary).inserted else { continue }
            fresh.append(request)
        }
        guard !fresh.isEmpty else { return }
        // The latest screen matters most: its items go ahead of older, possibly scrolled-away ones.
        warmQueue.insert(contentsOf: fresh, at: 0)
        if warmQueue.count > 600 {
            for dropped in warmQueue[600...] { warmQueued.remove(dropped.primary) }
            warmQueue.removeSubrange(600...)
        }
        startWarming()
    }

    private func startWarming() {
        while warmRunning < Self.warmConcurrency, !warmQueue.isEmpty {
            let request = warmQueue.removeFirst()
            warmQueued.remove(request.primary)
            guard dataInFlight[request.primary] == nil,
                  !isCoolingDown(request.primary, in: &failedRequests),
                  !isCoolingDown(request.primary, in: &warmFailedRequests),
                  !warmServedFromDisk(request) else { continue }
            warmRunning += 1
            let disk = disk, session = prefetchSession
            // Registered like any fetch, so an on-screen decode of the same image joins it.
            let entry = InFlight(task: Task.detached(priority: .utility) {
                await Self.encodedData(for: request, disk: disk, session: session)
            })
            entry.waiters = 1
            entry.warmOwned = true
            dataInFlight[request.primary] = entry
            let token = ObjectIdentifier(entry)
            Task(priority: .utility) {
                let data = await entry.task.value
                // Warm failures cool the warm path only — a throttled background timeout
                // must not mark the URL dead for on-screen loads (`failedRequests`); the
                // `warmOwned` flag inside `releaseData` is what keeps it that way.
                self.releaseData(request.primary, token: token, finished: true, failed: data == nil)
                if data == nil, !entry.task.isCancelled {
                    self.noteFailure(&self.warmFailedRequests, request.primary)
                }
                self.warmRunning -= 1
                self.startWarming()
            }
        }
    }

    private func release(_ key: Key, token: ObjectIdentifier, finished: Bool) {
        guard let entry = inFlight[key], ObjectIdentifier(entry) == token else { return }
        if finished {
            // The result is in the memory cache now; later callers hit it directly.
            inFlight[key] = nil
            return
        }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            // Last interested caller went away: stop the download/decoding.
            entry.task.cancel()
            inFlight[key] = nil
        }
    }
}

/// Drives the data tasks `ImagePipeline.download` creates manually. The async `URLSession`
/// APIs (`data(from:)`, `bytes(from:)`, completion-handler tasks) bypass session delegates on
/// macOS 26 — verified empirically — so header checks and the byte cap can only live here.
///
/// Callbacks arrive on each session's serial delegate queue; `pending` is locked because the
/// foreground and prefetch sessions have separate queues. Every resumed task produces exactly
/// one `didCompleteWithError`, which is the single point where the continuation resumes.
private final class ImageDownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var data = Data()
        /// `Content-Length` hint used to pre-size the accumulation (0 = unknown).
        var hint = 0
        var continuation: CheckedContinuation<Data?, Never>?
    }

    private let pending = Mutex<[ObjectIdentifier: Pending]>([:])
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    /// Registers the continuation before `task.resume()`; safe even if the caller is already
    /// cancelled — a task cancelled before resume still reports `didCompleteWithError`.
    func begin(_ task: URLSessionDataTask, _ continuation: CheckedContinuation<Data?, Never>) {
        pending.withLock { $0[ObjectIdentifier(task)] = Pending(continuation: continuation) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            return
        }
        if let mime = response.mimeType?.lowercased(), mime.hasPrefix("text/") || mime.contains("json") || mime.contains("html") {
            completionHandler(.cancel)
            return
        }
        // Headers arrive before the body: refuse oversized payloads without consuming them.
        let expected = response.expectedContentLength
        if expected > Int64(limit) {
            completionHandler(.cancel)
            return
        }
        if expected > 0 {
            pending.withLock { $0[ObjectIdentifier(dataTask)]?.hint = Int(min(expected, Int64(limit))) }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let over = pending.withLock { state -> Bool in
            guard var entry = state[ObjectIdentifier(dataTask)] else { return true }
            if entry.data.isEmpty, entry.hint > 0 { entry.data.reserveCapacity(entry.hint) }
            entry.data.append(data)
            state[ObjectIdentifier(dataTask)] = entry
            return entry.data.count > limit
        }
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let entry = pending.withLock { $0.removeValue(forKey: ObjectIdentifier(task)) }
        // Any error — network failure, our own oversize/status/MIME cancel, caller cancel —
        // yields nil; only a clean finish returns the accumulated bytes.
        entry?.continuation?.resume(returning: error == nil ? entry?.data : nil)
    }
}

/// Bound expensive ImageIO work even when multiple shelves become visible at once.
/// Cancelled jobs leave the queue before they allocate decoded pixels.
private actor ImageDecodeQueue {
    private let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(limit: Int = 6) { self.limit = limit }

    /// Runs `work` off the actor once a slot is free. A `nil` result either comes from
    /// the work itself or means the task was cancelled before or during the wait.
    func decode<T: Sendable>(_ work: @Sendable () -> T?) async -> T? {
        guard !Task.isCancelled, await acquire() else { return nil }
        defer { release() }
        guard !Task.isCancelled else { return nil }
        return await Self.perform(work)
    }

    private func acquire() async -> Bool {
        if running < limit {
            running += 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        if waiting.isEmpty {
            running -= 1
        } else {
            waiting.removeFirst().continuation.resume(returning: true)
        }
    }

    @concurrent private nonisolated static func perform<T: Sendable>(_ work: @Sendable () -> T?) async -> T? {
        autoreleasepool(invoking: work)
    }
}

/// Thread-safe byte-cost memory cache keyed by the decode `Key`.
///
/// A plain dictionary + mutex replaces `NSCache<NSString, …>`: lookups hash the `Key` directly,
/// so the hot `RemoteImage.body` path allocates nothing (no per-eval `NSString` for the cache
/// key). Eviction approximates LRU — reads refresh a stamp — batched to ~20 % headroom so
/// inserts stay amortised O(1) apart from the occasional sort.
nonisolated final class MemoryCache: @unchecked Sendable {
    private struct Entry {
        let image: CGImage
        let bytes: Int
        var stamp: UInt64
    }

    private struct State {
        var entries: [ImagePipeline.Key: Entry] = [:]
        var bytes = 0
        var clock: UInt64 = 0
    }

    private let state = Mutex(State())
    private let byteLimit: Int
    private static let countLimit = 4096

    init(costLimit: Int) { byteLimit = costLimit }

    func image(for key: ImagePipeline.Key) -> CGImage? {
        state.withLock { state in
            state.clock &+= 1
            guard var entry = state.entries[key] else { return nil }
            entry.stamp = state.clock
            state.entries[key] = entry
            return entry.image
        }
    }

    func insert(_ image: CGImage, for key: ImagePipeline.Key) {
        let bytes = image.bytesPerRow * image.height
        state.withLock { state in
            state.clock &+= 1
            if let old = state.entries.updateValue(Entry(image: image, bytes: bytes, stamp: state.clock), forKey: key) {
                state.bytes -= old.bytes
            }
            state.bytes += bytes
            evict(&state)
        }
    }

    /// The least memory-heavy sharp (unblurred) entry cached for `url`, if any — used to
    /// derive average colours and blurred variants from artwork already decoded. Bounded by
    /// the count limit; a scan is a few µs and does not refresh recency (derivations are a
    /// bonus reuse, not a reason to keep artwork alive).
    func smallestSharpEntry(forURL url: URL) -> (key: ImagePipeline.Key, image: CGImage)? {
        state.withLock { state in
            var best: (key: ImagePipeline.Key, entry: Entry)?
            for (key, entry) in state.entries where key.url == url && key.blur == 0 {
                if best == nil || entry.bytes < best!.entry.bytes { best = (key, entry) }
            }
            return best.map { ($0.key, $0.entry.image) }
        }
    }

    /// Once a budget is exceeded, drops the stalest entries until back under ~80 % of both.
    /// The trigger is the limit itself, not the 80 % target: triggering at the target made
    /// every insert of a full cache sort all entries under the lock `RemoteImage.body` takes
    /// (measured: 1 500/1 500 steady-state poster inserts sorted, mean 104 µs, max 2.1 ms).
    private func evict(_ state: inout State) {
        let byteTarget = byteLimit * 8 / 10
        let countTarget = Self.countLimit * 8 / 10
        guard state.bytes > byteLimit || state.entries.count > Self.countLimit else { return }
        for (key, entry) in state.entries.sorted(by: { $0.value.stamp < $1.value.stamp }) {
            guard state.bytes > byteTarget || state.entries.count > countTarget else { break }
            state.entries[key] = nil
            state.bytes -= entry.bytes
        }
    }

    func removeAll() { state.withLock { $0 = State() } }
}
