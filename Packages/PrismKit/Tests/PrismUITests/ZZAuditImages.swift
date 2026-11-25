import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PrismDesign
@testable import PrismUI

/// ZZAudit — offscreen measurements for the REMAINING image-pipeline issues.
/// Prints timings; assertions are sanity checks only.
@Suite("ZZAudit images", .disabled(if: ProcessInfo.processInfo.environment["ZZAUDIT"] == nil))
struct ZZAuditImages {

    // MARK: Fixture helpers (same style as ImagePipelineTests)

    private func gradientImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let space = CGColorSpaceCreateDeviceRGB()
        let colors = [
            try #require(CGColor(colorSpace: space, components: [0.15, 0.2, 0.45, 1])),
            try #require(CGColor(colorSpace: space, components: [0.85, 0.55, 0.2, 1])),
        ] as CFArray
        let gradient = try #require(CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]
        ))
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: width, y: height), options: []
        )
        return try #require(context.makeImage())
    }

    private func writeImage(
        named name: String, width: Int, height: Int,
        format: UTType = .jpeg, directory: URL, quality: Double = 0.9
    ) throws -> URL {
        let image = try gradientImage(width: width, height: height)
        let url = directory.appending(path: name)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, format.identifier as CFString, 1, nil
        ))
        var properties: [CFString: Any] = [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return url
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "prism-image-audit-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bench(_ label: String, iterations: Int, _ body: () -> Void) {
        for _ in 0..<max(10, iterations / 10) { body() }
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations { body() }
        let elapsed = start.duration(to: clock.now)
        let perUs = elapsed / .microseconds(1) / Double(iterations)
        print("ZZAUDIT \(label): \(String(format: "%.1f", perUs)) µs/op over \(iterations) iters")
    }

    // MARK: Decode cost — isDecodable + thumbnail at card/hero sizes

    @Test func decodeCostCardAndHero() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeImage(named: "still.jpg", width: 1920, height: 1080, directory: directory)
        let data = try Data(contentsOf: url)
        print("ZZAUDIT fixture jpeg bytes: \(data.count)")

        bench("isDecodable(jpeg)", iterations: 200) {
            #expect(ImageDecoder.isDecodable(data))
        }

        let cardTarget = CGSize(width: 512, height: 288)
        bench("decode card 512×288 fill", iterations: 60) {
            #expect(ImageDecoder.decode(data, target: cardTarget, fitting: .fill, fillsForBlur: false) != nil)
        }

        let heroTarget = CGSize(width: 3072, height: 1280)
        bench("decode hero 3072×1280 landscapeFill", iterations: 20) {
            #expect(ImageDecoder.decode(data, target: heroTarget, fitting: .landscapeFill, fillsForBlur: false) != nil)
        }

        let sharp = try #require(ImageDecoder.decode(data, target: cardTarget, fitting: .fill, fillsForBlur: false))
        bench("blurred() 512px sharp → 96px", iterations: 200) {
            #expect(ImageDecoder.blurred(sharp, radius: 6, target: CGSize(width: 96, height: 96)) != nil)
        }

        let hero = try #require(ImageDecoder.decode(data, target: heroTarget, fitting: .landscapeFill, fillsForBlur: false))
        print("ZZAUDIT hero decoded: \(hero.width)×\(hero.height) bpr=\(hero.bytesPerRow)")
        let clock = ContinuousClock()
        var sink: RGBA?
        let start = clock.now
        for _ in 0..<30 {
            sink = ImageDecoder.averageColor(of: hero)
        }
        let per = (start.duration(to: clock.now)) / .microseconds(1) / 30
        print("ZZAUDIT averageColor(hero \(hero.width)×\(hero.height)): \(String(format: "%.0f", per)) µs each")
        #expect(sink != nil)

        // Same cost at card scale — this is what EVERY poster decode pays inline.
        let card = try #require(ImageDecoder.decode(data, target: cardTarget, fitting: .fill, fillsForBlur: false))
        let start2 = clock.now
        for _ in 0..<60 {
            sink = ImageDecoder.averageColor(of: card)
        }
        let per2 = start2.duration(to: clock.now) / .microseconds(1) / 60
        print("ZZAUDIT averageColor(card \(card.width)×\(card.height)): \(String(format: "%.0f", per2)) µs each")
        #expect(sink != nil)
    }

    // MARK: Hot-path costs (RemoteImage.body → key → memory lookup)

    @Test func hotPathCosts() throws {
        let url = try #require(URL(string: "https://image.tmdb.org/t/p/w500/abc_def_very_long_poster_name.jpg"))
        let points = CGSize(width: 150, height: 225)
        bench("pixelSize+key (RemoteImage.loadKey)", iterations: 20_000) {
            let pixels = RemoteImage.pixelSize(forPointSize: points, scale: 2)
            _ = ImagePipeline.key(url: url, pixelSize: pixels, fitting: .fill, blurRadius: 0)
        }

        bench("ArtworkURL.resolve (per decode + per warm URL)", iterations: 20_000) {
            _ = ArtworkURL.resolve(url, target: CGSize(width: 320, height: 512), fitting: .fill, fillsForBlur: false)
        }

        let cache = MemoryCache(costLimit: 8 << 20)
        let key = try #require(ImagePipeline.key(url: url, pixelSize: CGSize(width: 300, height: 450), fitting: .fill, blurRadius: 0))
        let img = try gradientImage(width: 64, height: 96)
        cache.insert(img, for: key)
        bench("MemoryCache.image(for:) hit", iterations: 100_000) {
            _ = cache.image(for: key)
        }
    }

    // MARK: Disk cache read cost (what warm() pays per already-cached URL)

    @Test func diskReadCost() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageDiskCache(directory: directory, capacity: 64 << 20)
        let payload = Data((0..<150_000).map { UInt8($0 % 251) })
        let urls = (0..<200).map { URL(string: "https://img.test/poster/\($0).jpg")! }
        for u in urls { cache.store(payload, for: u) }

        _ = cache.data(for: urls[0])
        bench("disk.data(for:) hit (SHA256 + mmap + mutex)", iterations: 5_000) {
            #expect(cache.data(for: urls[7])?.count == payload.count)
        }
        let clock = ContinuousClock()
        let start = clock.now
        for u in urls.prefix(6) { _ = cache.data(for: u) }
        print("ZZAUDIT warm-burst 6 cached URLs: \(start.duration(to: clock.now))")
    }

    // MARK: Pipeline memory-hit latency + burst decode

    @Test func pipelineMemoryHitLatency() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ImagePipeline(memoryCapacity: 64 << 20, diskCapacity: 64 << 20, diskDirectory: directory)
        let url = try writeImage(named: "hit.jpg", width: 600, height: 900, directory: directory)
        _ = await pipeline.image(for: url, maxPixelSize: 300)

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<500 {
            _ = await pipeline.image(for: url, maxPixelSize: 300)
        }
        let per = start.duration(to: clock.now) / .microseconds(1) / 500
        print("ZZAUDIT pipeline.image() memory-hit: \(String(format: "%.1f", per)) µs/call")
    }

    @Test func burstDecode() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ImagePipeline(memoryCapacity: 64 << 20, diskCapacity: 64 << 20, diskDirectory: directory)
        var urls: [URL] = []
        for i in 0..<24 {
            urls.append(try writeImage(named: "p\(i).jpg", width: 600, height: 900, directory: directory))
        }
        let clock = ContinuousClock()
        let start = clock.now
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = await pipeline.image(for: url, maxPixelSize: 300) }
            }
        }
        print("ZZAUDIT 24 concurrent card decodes (file://): \(start.duration(to: clock.now))")
        let start2 = clock.now
        await withTaskGroup(of: Void.self) { group in
            for url in urls {
                group.addTask { _ = await pipeline.image(for: url, maxPixelSize: 300) }
            }
        }
        print("ZZAUDIT 24 memory-cache hits: \(start2.duration(to: clock.now))")
    }

    // MARK: Network-failure cooldown — per-call latency

    @Test func networkFailureCooldown() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipeline = ImagePipeline(memoryCapacity: 4 << 20, diskCapacity: 4 << 20, diskDirectory: directory)
        let dead = URL(string: "http://127.0.0.1:1/dead.jpg")!

        let clock = ContinuousClock()
        var times: [Double] = []
        for i in 0..<6 {
            let t = clock.now
            #expect(await pipeline.image(for: dead, maxPixelSize: 100) == nil)
            times.append(t.duration(to: clock.now) / .milliseconds(1))
            print("ZZAUDIT dead-url attempt \(i): \(String(format: "%.1f", times.last!)) ms")
        }
        // Different size → same URL → cooldown is per-URL?
        let t2 = clock.now
        #expect(await pipeline.image(for: dead, pixelSize: CGSize(width: 640, height: 480), fitting: .fill) == nil)
        print("ZZAUDIT dead-url different-size retry: \(t2.duration(to: clock.now) / .milliseconds(1)) ms")
    }

    // MARK: Decode-failure cooldown — per-call latency

    @Test func decodeFailureCooldown() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeImage(named: "poster.jpg", width: 600, height: 900, directory: directory)
        let pipeline = ImagePipeline(memoryCapacity: 4 << 20, diskCapacity: 4 << 20, diskDirectory: directory)
        let bad = CGSize(width: 640, height: 360)
        for i in 0..<8 {
            let t = ContinuousClock.now
            #expect(await pipeline.image(for: url, pixelSize: bad, fitting: .landscapeFill) == nil)
            print("ZZAUDIT rejected-decode attempt \(i): \(t.duration(to: .now) / .milliseconds(1)) ms")
        }
        #expect(await pipeline.image(for: url, pixelSize: CGSize(width: 320, height: 480), fitting: .portraitFit) != nil)
    }
}
