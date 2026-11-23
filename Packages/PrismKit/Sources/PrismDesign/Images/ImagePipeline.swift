import CoreGraphics
import Foundation
import SwiftUI

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
        var cacheKey: NSString { "\(width)x\(height)|\(fitting.rawValue)|\(blur)|\(url.absoluteString)" as NSString }

        func showsSameArtwork(as other: Key) -> Bool {
            url == other.url && fitting == other.fitting && blur == other.blur
        }
    }

    /// A shared task with a count of interested callers (cancelled when nobody waits anymore).
    private final class InFlight<Value: Sendable> {
        let task: Task<Value, Never>
        var waiters = 0
        init(task: Task<Value, Never>) { self.task = task }
    }

    private let memory: MemoryCache
    private let disk: ImageDiskCache
    private let decoder = ImageDecodeQueue()
    private lazy var session = Self.makeSession(warming: false)
    /// Background warm-ups use their own small connection pool so they never queue ahead of
    /// artwork that is on screen.
    private lazy var prefetchSession = Self.makeSession(warming: true)
    private var inFlight: [Key: InFlight<CGImage?>] = [:]
    /// Encoded-bytes fetches, shared by every decode of the same URL (sharp + blurred, sizes).
    private var dataInFlight: [URL: InFlight<Data?>] = [:]
    private var failedRequests: [URL: ContinuousClock.Instant] = [:]
    private var prefetches: [URL: Task<Void, Never>] = [:]
    private var averageColors: [URL: RGBA?] = [:]
    /// Byte warm-ups waiting for a slot, most recent request first.
    private var warmQueue: [ArtworkURL.Resolved] = []
    private var warmQueued: Set<URL> = []
    private var warmRunning = 0
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
        configuration.httpAdditionalHeaders = ["Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"]
        if warming { configuration.networkServiceType = .background }
        return URLSession(configuration: configuration)
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

        let entry: InFlight<CGImage?>
        if let existing = inFlight[key] {
            entry = existing
        } else {
            entry = InFlight(task: makeTask(for: key, blurredFrom: source))
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
        Task(priority: .utility) { await self.enqueueWarm(urls, target: target, fitting: fitting) }
    }

    /// Warms the caches for upcoming items (low priority, de-duplicated).
    public nonisolated func prefetch(_ urls: [URL], maxPixelSize: CGFloat) {
        guard !urls.isEmpty else { return }
        Task(priority: .utility) { await self.startPrefetch(urls, pixelSize: CGSize(width: maxPixelSize, height: maxPixelSize), fitting: .fit) }
    }

    /// Warms the caches for a fill target (same key as `RemoteImage` with that size).
    public nonisolated func prefetch(_ urls: [URL], pixelSize: CGSize) {
        guard !urls.isEmpty else { return }
        Task(priority: .utility) { await self.startPrefetch(urls, pixelSize: pixelSize, fitting: .fill) }
    }

    /// Cancels pending prefetches for `urls` (all when `nil`).
    public nonisolated func cancelPrefetch(_ urls: [URL]? = nil) {
        Task { await self.stopPrefetch(urls) }
    }

    /// Average (vibrance-boosted) colour of the image, cached per URL.
    public func averageColor(for url: URL) async -> Color? {
        await averageRGBA(for: url)?.color
    }

    /// Average colour as plain components (for gradients/tinting maths).
    public func averageRGBA(for url: URL) async -> RGBA? {
        if let cached = averageColors[url] { return cached }
        guard let image = await image(for: url, maxPixelSize: 64) else { return nil }
        let rgba = await ImageDecoder.averageColor(of: image)
        averageColors[url] = rgba
        if averageColors.count > 4000 { averageColors.removeAll(keepingCapacity: true) }
        return rgba
    }

    /// Synchronous lookup of an already computed average colour.
    public func cachedAverageColor(for url: URL) -> Color? {
        averageColors[url]??.color
    }

    /// Drops the memory cache (e.g. on memory pressure); the disk cache is kept.
    public nonisolated func purgeMemory() { memory.removeAll() }

    /// Removes every cached image (memory + disk).
    public func removeAll() {
        memory.removeAll()
        disk.removeAll()
        averageColors.removeAll()
        failedRequests.removeAll()
    }

    // MARK: Internals

    private static let pixelBuckets = [32, 64, 96, 128, 192, 256, 320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 2048, 2560, 3072]

    private nonisolated static func bucket(for pixels: CGFloat) -> Int {
        let value = Int(min(4096, pixels.rounded(.up)))
        for step in pixelBuckets where value <= step {
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

    private func makeTask(for key: Key, blurredFrom source: Key?) -> Task<CGImage?, Never> {
        let memory = memory
        let decoder = decoder
        let blur = CGFloat(key.blur)
        let target = key.target
        return Task.detached(priority: .userInitiated) {
            let image: CGImage?
            if blur > 0, let source {
                guard let sharp = await self.image(for: source) else { return nil }
                image = await decoder.decode {
                    return ImageDecoder.blurred(sharp, radius: blur * 0.25, target: target)
                }
            } else if key.url.isFileURL {
                image = await decoder.decode {
                    let thumbnail = ImageDecoder.decode(fileURL: key.url, target: target, fitting: key.fitting, fillsForBlur: blur > 0)
                    return thumbnail.flatMap { blur > 0 ? ImageDecoder.blurred($0, radius: blur * 0.25) : $0 }
                }
            } else if let data = await self.sharedData(
                for: ArtworkURL.resolve(key.url, target: target, fitting: key.fitting, fillsForBlur: blur > 0)
            ) {
                image = await decoder.decode {
                    let thumbnail = ImageDecoder.decode(data, target: target, fitting: key.fitting, fillsForBlur: blur > 0)
                    return thumbnail.flatMap { blur > 0 ? ImageDecoder.blurred($0, radius: blur * 0.25) : $0 }
                }
            } else {
                image = nil
            }
            if let image, !Task.isCancelled {
                memory.insert(image, for: key)
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
            guard !isCoolingDown(url) else { return nil }
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

    private func releaseData(_ url: URL, token: ObjectIdentifier, finished: Bool, failed: Bool = false) {
        guard let entry = dataInFlight[url], ObjectIdentifier(entry) == token else { return }
        if finished {
            dataInFlight[url] = nil
            if failed, !entry.task.isCancelled {
                if failedRequests.count >= 2_048 {
                    let now = ContinuousClock.now
                    failedRequests = failedRequests.filter { $0.value > now }
                    if failedRequests.count >= 2_048 {
                        for key in Array(failedRequests.keys.prefix(128)) { failedRequests[key] = nil }
                    }
                }
                failedRequests[url] = ContinuousClock.now.advanced(by: .seconds(120))
            }
            return
        }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            dataInFlight[url] = nil
        }
    }

    private func isCoolingDown(_ url: URL) -> Bool {
        guard let expiry = failedRequests[url] else { return false }
        if expiry > ContinuousClock.now { return true }
        failedRequests[url] = nil
        return false
    }

    /// Disk hit, else network (validated as an image before being stored). A resized TMDB request
    /// falls back to the provider's own URL, from disk when its copy is large enough, else online.
    @concurrent private nonisolated static func encodedData(for request: ArtworkURL.Resolved, disk: ImageDiskCache, session: URLSession) async -> Data? {
        if let data = disk.data(for: request.primary) { return data }
        if request.fallbackIsLarger, let fallback = request.fallback, let data = disk.data(for: fallback) { return data }
        if let data = await download(request.primary, disk: disk, session: session) { return data }
        guard !Task.isCancelled, let fallback = request.fallback else { return nil }
        if !request.fallbackIsLarger, let data = disk.data(for: fallback) { return data }
        return await download(fallback, disk: disk, session: session)
    }

    @concurrent private nonisolated static func download(_ url: URL, disk: ImageDiskCache, session: URLSession) async -> Data? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
            if let mime = response.mimeType?.lowercased(), mime.hasPrefix("text/") || mime.contains("json") || mime.contains("html") {
                return nil
            }
            guard ImageDecoder.isDecodable(data) else { return nil }
            disk.store(data, for: url)
            return data
        } catch {
            return nil
        }
    }

    private func enqueueWarm(_ urls: [URL], target: CGSize, fitting: Fitting) {
        var fresh: [ArtworkURL.Resolved] = []
        for url in urls where !url.isFileURL {
            let request = ArtworkURL.resolve(url, target: target, fitting: fitting, fillsForBlur: false)
            guard dataInFlight[request.primary] == nil, !isCoolingDown(request.primary),
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
            guard dataInFlight[request.primary] == nil, !isCoolingDown(request.primary) else { continue }
            warmRunning += 1
            let disk = disk, session = prefetchSession
            // Registered like any fetch, so an on-screen decode of the same image joins it.
            let entry = InFlight(task: Task.detached(priority: .utility) {
                await Self.encodedData(for: request, disk: disk, session: session)
            })
            entry.waiters = 1
            dataInFlight[request.primary] = entry
            let token = ObjectIdentifier(entry)
            Task(priority: .utility) {
                let data = await entry.task.value
                self.releaseData(request.primary, token: token, finished: true, failed: data == nil)
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

    private func startPrefetch(_ urls: [URL], pixelSize: CGSize, fitting: Fitting) {
        for url in urls where prefetches[url] == nil {
            guard let key = Self.key(url: url, pixelSize: pixelSize, fitting: fitting, blurRadius: 0),
                  memory.image(for: key) == nil else { continue }
            prefetches[url] = Task(priority: .utility) {
                _ = await self.image(for: key)
                self.prefetchFinished(url)
            }
        }
    }

    private func prefetchFinished(_ url: URL) { prefetches[url] = nil }

    private func stopPrefetch(_ urls: [URL]?) {
        if let urls {
            for url in urls { prefetches.removeValue(forKey: url)?.cancel() }
        } else {
            prefetches.values.forEach { $0.cancel() }
            prefetches.removeAll()
        }
    }
}

/// Bound expensive ImageIO work even when multiple shelves become visible at once.
/// Cancelled jobs leave the queue before they allocate decoded pixels.
private actor ImageDecodeQueue {
    private let limit = 6
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    func decode(_ work: @Sendable () -> CGImage?) async -> CGImage? {
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

    @concurrent private nonisolated static func perform(_ work: @Sendable () -> CGImage?) async -> CGImage? {
        autoreleasepool(invoking: work)
    }
}

/// Thread-safe byte-cost memory cache.
nonisolated final class MemoryCache: @unchecked Sendable {
    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()

    init(costLimit: Int) {
        cache.totalCostLimit = costLimit
        cache.countLimit = 4000
    }

    func image(for key: ImagePipeline.Key) -> CGImage? {
        cache.object(forKey: key.cacheKey)?.image
    }

    func insert(_ image: CGImage, for key: ImagePipeline.Key) {
        cache.setObject(Box(image), forKey: key.cacheKey, cost: image.bytesPerRow * image.height)
    }

    func removeAll() { cache.removeAllObjects() }
}
