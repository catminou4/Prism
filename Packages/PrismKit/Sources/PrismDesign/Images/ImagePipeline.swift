import CoreGraphics
import Foundation
import SwiftUI

/// Shared image loader: request de-duplication, memory cache (≈ 256 MB, byte cost), disk cache
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
    }

    nonisolated struct Key: Hashable, Sendable {
        let url: URL
        let bucket: Int
        let fitting: Fitting
        let blur: Int

        var cacheKey: NSString { "\(bucket)|\(fitting.rawValue)|\(blur)|\(url.absoluteString)" as NSString }
    }

    /// A shared task with a count of interested callers (cancelled when nobody waits anymore).
    private final class InFlight<Value: Sendable> {
        let task: Task<Value, Never>
        var waiters = 0
        init(task: Task<Value, Never>) { self.task = task }
    }

    private let memory: MemoryCache
    private let disk: ImageDiskCache
    private let session: URLSession
    private var inFlight: [Key: InFlight<CGImage?>] = [:]
    /// Encoded-bytes fetches, shared by every decode of the same URL (sharp + blurred, sizes).
    private var dataInFlight: [URL: InFlight<Data?>] = [:]
    private var prefetches: [URL: Task<Void, Never>] = [:]
    private var averageColors: [URL: RGBA?] = [:]

    public init(memoryCapacity: Int = 256 << 20, diskCapacity: Int = 1 << 30, diskDirectory: URL? = nil) {
        memory = MemoryCache(costLimit: memoryCapacity)
        disk = ImageDiskCache(directory: diskDirectory, capacity: diskCapacity)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil // the disk cache below stores the encoded bytes
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["Accept": "image/avif,image/webp,image/png,image/jpeg,image/*;q=0.8"]
        session = URLSession(configuration: configuration)
    }

    // MARK: Public API

    /// Image whose longest side is at most `maxPixelSize` pixels.
    public func image(for url: URL, maxPixelSize: CGFloat) async -> CGImage? {
        await image(for: url, pixelSize: CGSize(width: maxPixelSize, height: maxPixelSize), fitting: .fit)
    }

    /// Image decoded for a `pixelSize` target (pass points × display scale).
    /// `blurRadius > 0` returns a pre-blurred low-resolution version (cheap to display upscaled).
    public func image(for url: URL, pixelSize: CGSize, fitting: Fitting = .fill, blurRadius: CGFloat = 0) async -> CGImage? {
        let key = Self.key(url: url, pixelSize: pixelSize, fitting: fitting, blurRadius: blurRadius)
        if let hit = memory.image(for: key) { return hit }

        let entry: InFlight<CGImage?>
        if let existing = inFlight[key] {
            entry = existing
        } else {
            entry = InFlight(task: makeTask(for: key, pixelSize: pixelSize))
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
        return result
    }

    /// Synchronous memory-cache lookup (use from `body` to avoid placeholder flashes).
    public nonisolated func cachedImage(for url: URL, pixelSize: CGSize, fitting: Fitting = .fill, blurRadius: CGFloat = 0) -> CGImage? {
        memory.image(for: Self.key(url: url, pixelSize: pixelSize, fitting: fitting, blurRadius: blurRadius))
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
    }

    // MARK: Internals

    nonisolated static func bucket(for pixels: CGFloat) -> Int {
        let value = Int(pixels.rounded(.up))
        for step in [32, 64, 96, 128, 192, 256, 320, 384, 448, 512, 640, 768, 896, 1024, 1280, 1536, 2048, 2560, 3072] where value <= step {
            return step
        }
        return 4096
    }

    nonisolated static func key(url: URL, pixelSize: CGSize, fitting: Fitting, blurRadius: CGFloat) -> Key {
        // Blurred variants are always small: they are displayed upscaled.
        let longest = blurRadius > 0 ? 96 : max(pixelSize.width, pixelSize.height)
        // Fill targets are bucketed on both sides' aspect so 2:3 and 16:9 slots don't collide.
        let aspectTag = fitting == .fill && pixelSize.height > 0 ? Int((pixelSize.width / pixelSize.height * 8).rounded()) : 0
        return Key(url: url, bucket: bucket(for: longest) * 100 + aspectTag, fitting: fitting, blur: Int(blurRadius.rounded()))
    }

    private func makeTask(for key: Key, pixelSize: CGSize) -> Task<CGImage?, Never> {
        let memory = memory
        let blur = CGFloat(key.blur)
        let fill = key.fitting == .fill
        // Target in pixels, rounded up to the bucket so cached images serve slightly bigger slots.
        let longest = max(pixelSize.width, pixelSize.height)
        let bucketScale = blur > 0 ? 1 : CGFloat(key.bucket / 100) / max(longest, 1)
        let target = blur > 0
            ? CGSize(width: 96, height: 96)
            : CGSize(width: (pixelSize.width * bucketScale).rounded(.up), height: (pixelSize.height * bucketScale).rounded(.up))
        return Task.detached(priority: .userInitiated) {
            var image: CGImage?
            if key.url.isFileURL {
                image = await ImageDecoder.decode(fileURL: key.url, target: target, fill: fill || blur > 0)
            } else if let data = await self.sharedData(for: key.url) {
                image = await ImageDecoder.decode(data, target: target, fill: fill || blur > 0)
            }
            if let decoded = image, blur > 0 {
                image = await ImageDecoder.blurred(decoded, radius: blur * 0.25)
            }
            if let image, !Task.isCancelled {
                memory.insert(image, for: key)
            }
            return image
        }
    }

    /// Encoded bytes for `url`, fetched once even when several decodes need them concurrently.
    private func sharedData(for url: URL) async -> Data? {
        let entry: InFlight<Data?>
        if let existing = dataInFlight[url] {
            entry = existing
        } else {
            let disk = disk, session = session
            entry = InFlight(task: Task.detached(priority: .userInitiated) {
                await Self.encodedData(for: url, disk: disk, session: session)
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
        releaseData(url, token: token, finished: true)
        return data
    }

    private func releaseData(_ url: URL, token: ObjectIdentifier, finished: Bool) {
        guard let entry = dataInFlight[url], ObjectIdentifier(entry) == token else { return }
        if finished {
            // Bytes are on disk now (or the fetch failed): later decodes read the disk cache.
            dataInFlight[url] = nil
            return
        }
        entry.waiters -= 1
        if entry.waiters <= 0 {
            entry.task.cancel()
            dataInFlight[url] = nil
        }
    }

    /// Disk hit, else network (validated as an image before being stored).
    @concurrent private nonisolated static func encodedData(for url: URL, disk: ImageDiskCache, session: URLSession) async -> Data? {
        if let data = disk.data(for: url) { return data }
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
            if memory.image(for: Self.key(url: url, pixelSize: pixelSize, fitting: fitting, blurRadius: 0)) != nil { continue }
            prefetches[url] = Task(priority: .utility) {
                _ = await self.image(for: url, pixelSize: pixelSize, fitting: fitting)
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
