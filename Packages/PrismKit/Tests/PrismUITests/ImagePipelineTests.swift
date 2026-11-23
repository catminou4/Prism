import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PrismDesign

/// Decode-size correctness, cache behaviour and pipeline end-to-end checks for `ImagePipeline`.
/// All fixtures are generated in-test — no network, no binary blobs.
@Suite("Pipeline d'images")
struct ImagePipelineTests {
    // MARK: Fixture helpers

    /// A bitmap filled with a diagonal gradient so encoders produce real image data.
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

    /// Writes `width`×`height` artwork as JPEG (or PNG) into `directory`.
    private func writeImage(
        named name: String, width: Int, height: Int,
        format: UTType = .jpeg, directory: URL
    ) throws -> URL {
        let image = try gradientImage(width: width, height: height)
        let url = directory.appending(path: name)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, format.identifier as CFString, 1, nil
        ))
        var properties: [CFString: Any] = [:]
        if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return url
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "prism-image-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeKey(_ string: String, _ width: CGFloat, _ height: CGFloat,
                         _ fitting: ImagePipeline.Fitting = .fit, blur: CGFloat = 0) throws -> ImagePipeline.Key {
        let url = try #require(URL(string: string))
        return try #require(ImagePipeline.key(
            url: url,
            pixelSize: CGSize(width: width, height: height), fitting: fitting, blurRadius: blur
        ))
    }

    // MARK: ImageDecoder — display-size decode

    @Test func fillDecodeCoversTheTarget() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 2:3 poster, 600×900.
        let url = try writeImage(named: "poster.jpg", width: 600, height: 900, directory: directory)
        let data = try Data(contentsOf: url)

        // Target 320×512 fill: the decoded thumbnail must cover it (aspect preserved).
        let image = try #require(ImageDecoder.decode(
            data, target: CGSize(width: 320, height: 512), fitting: .fill, fillsForBlur: false
        ))
        #expect(image.width >= 320)
        #expect(image.height >= 512)
        // Aspect stays 2:3 and stays close to the analytic size (~341×512).
        let aspect = Double(image.width) / Double(image.height)
        #expect(abs(aspect - 2.0 / 3.0) < 0.02)
        #expect(image.height <= 560, "decode should stay near the target, not balloon")
    }

    @Test func fitDecodeStaysInsideTheTarget() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Square logo 400×400 into a 64×64 fit slot.
        let url = try writeImage(named: "logo.png", width: 400, height: 400, format: .png, directory: directory)
        let data = try Data(contentsOf: url)

        let image = try #require(ImageDecoder.decode(
            data, target: CGSize(width: 64, height: 64), fitting: .fit, fillsForBlur: false
        ))
        #expect(image.width <= 72 && image.height <= 72)
        #expect(image.width >= 48 && image.height >= 48, "fit keeps useful resolution, not a token thumbnail")
        #expect(abs(Double(image.width) / Double(image.height) - 1) < 0.02)
    }

    @Test func landscapeFillRejectsPortraitArtwork() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeImage(named: "poster.jpg", width: 600, height: 900, directory: directory)
        let data = try Data(contentsOf: url)

        #expect(ImageDecoder.decode(
            data, target: CGSize(width: 640, height: 360), fitting: .landscapeFill, fillsForBlur: false
        ) == nil)
        // …but the same bytes decode fine for a portrait fit.
        #expect(ImageDecoder.decode(
            data, target: CGSize(width: 320, height: 480), fitting: .portraitFit, fillsForBlur: false
        ) != nil)
    }

    @Test func undecodableDataReturnsNil() {
        let garbage = Data("this is not an image".utf8)
        #expect(!ImageDecoder.isDecodable(garbage))
        #expect(ImageDecoder.decode(
            garbage, target: CGSize(width: 100, height: 100), fitting: .fill, fillsForBlur: false
        ) == nil)
        // Empty and tiny payloads are rejected before touching ImageIO.
        #expect(!ImageDecoder.isDecodable(Data()))
        #expect(!ImageDecoder.isDecodable(Data(repeating: 0, count: 8)))
    }

    @Test func extremeAspectSourcesStayInsideTheDecodeCap() throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 16:1 panorama into a portrait fill slot: covering the height would need
        // ~8 000 px wide — the 4 096 px decode cap must hold instead.
        let url = try writeImage(named: "pano.jpg", width: 8000, height: 500, directory: directory)
        let data = try Data(contentsOf: url)
        let image = try #require(ImageDecoder.decode(
            data, target: CGSize(width: 320, height: 512), fitting: .fill, fillsForBlur: false
        ))
        #expect(max(image.width, image.height) <= 4_096)
        #expect(image.width > 2_000, "the capped decode still carries real resolution")
    }

    // MARK: Pipeline end-to-end (file:// URLs — no network)

    @Test func pipelineDecodesCachesAndReuses() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageDirectory = directory.appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        let url = try writeImage(named: "film.jpg", width: 800, height: 1200, directory: imageDirectory)

        let pipeline = ImagePipeline(memoryCapacity: 8 << 20, diskCapacity: 4 << 20, diskDirectory: directory)

        let image = try #require(await pipeline.image(for: url, maxPixelSize: 300))
        // .fit into a 300 px square of a 2:3 poster → ~213×320.
        #expect(image.width <= 220 && image.height <= 330)
        #expect(image.height >= 300, "fit keeps the poster's height resolution")

        // Second call is a memory hit: same CGImage instance, no re-decode.
        let second = await pipeline.image(for: url, maxPixelSize: 300)
        #expect(second === image)
        let cached = pipeline.cachedImage(for: url, pixelSize: CGSize(width: 300, height: 300), fitting: .fit)
        #expect(cached === image)

        // A different size is a different cache entry.
        let larger = await pipeline.image(for: url, maxPixelSize: 600)
        #expect(larger != nil)
        if let larger { #expect(!(larger === image)) }

        // Average colour is memoized from the decode.
        let color = await pipeline.averageRGBA(for: url)
        #expect(color != nil)
    }

    @Test func pipelineReturnsNilForGarbageAndCoolsDownDecodeFailures() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bad = directory.appending(path: "bad.jpg")
        try Data("definitely not an image".utf8).write(to: bad)

        let pipeline = ImagePipeline(memoryCapacity: 1 << 20, diskCapacity: 1 << 20, diskDirectory: directory)
        #expect(await pipeline.image(for: bad, maxPixelSize: 100) == nil)
        #expect(await pipeline.image(for: bad, maxPixelSize: 100) == nil)

        // A decode rejection is per-key: a fitting the artwork can't satisfy fails, while
        // a fitting it can must still decode (the negative cache must not poison other keys).
        let directory2 = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory2) }
        let poster = try writeImage(named: "poster.jpg", width: 600, height: 900, directory: directory2)
        let pipeline2 = ImagePipeline(memoryCapacity: 4 << 20, diskCapacity: 4 << 20, diskDirectory: directory2)
        let rejected = await pipeline2.image(
            for: poster, pixelSize: CGSize(width: 640, height: 360), fitting: .landscapeFill
        )
        #expect(rejected == nil)
        #expect(await pipeline2.image(
            for: poster, pixelSize: CGSize(width: 320, height: 480), fitting: .portraitFit
        ) != nil)
    }

    @Test func pipelineProducesBlurredVariant() async throws {
        let directory = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try writeImage(named: "still.jpg", width: 640, height: 360, directory: directory)
        let pipeline = ImagePipeline(memoryCapacity: 4 << 20, diskCapacity: 4 << 20, diskDirectory: directory)
        let blurred = await pipeline.image(for: url, pixelSize: CGSize(width: 400, height: 225), fitting: .fill, blurRadius: 24)
        let image = try #require(blurred)
        // Blurs decode small: the stored bitmap stays under the 384 px blur cap, not the slot size.
        #expect(max(image.width, image.height) <= 384)
    }

    // MARK: MemoryCache — byte cost + eviction

    @Test func memoryCacheEvictsByByteCost() throws {
        // Each bitmap is 128×128 RGBA ≈ 64 KiB decoded; budget 200 KiB → ~3 entries fit.
        let cache = MemoryCache(costLimit: 200 << 10)
        let k0 = try makeKey("https://example.com/0.jpg", 256, 256)
        let k1 = try makeKey("https://example.com/1.jpg", 256, 256)
        let k2 = try makeKey("https://example.com/2.jpg", 256, 256)
        let k3 = try makeKey("https://example.com/3.jpg", 256, 256)

        cache.insert(try gradientImage(width: 128, height: 128), for: k0)   // 64 K
        cache.insert(try gradientImage(width: 128, height: 128), for: k1)   // 128 K
        cache.insert(try gradientImage(width: 128, height: 128), for: k2)   // 192 K ≤ 200 K → nothing evicted
        // Reading k0 and k1 refreshes their recency: k2 becomes the stalest.
        #expect(cache.image(for: k0) != nil)
        #expect(cache.image(for: k1) != nil)

        // 256 K > 200 K → evicts the stalest until ≤ 160 K: k2, then k0 (k1 was read after k0).
        _ = cache.image(for: k1)
        cache.insert(try gradientImage(width: 128, height: 128), for: k3)
        #expect(cache.image(for: k2) == nil)
        #expect(cache.image(for: k0) == nil)
        #expect(cache.image(for: k1) != nil)
        #expect(cache.image(for: k3) != nil)
    }

    // MARK: Keying & sizing helpers

    @Test func pixelSizeQuantisesToEightPixels() throws {
        let size = RemoteImage.pixelSize(forPointSize: CGSize(width: 150, height: 225), scale: 2)
        #expect(size.width.truncatingRemainder(dividingBy: 8) == 0)
        #expect(size.height.truncatingRemainder(dividingBy: 8) == 0)
        // 300×450 → rounds up to a multiple of 8.
        #expect(size.width == 304 && size.height == 456)
        // 1× scale quantises the same way.
        let sd = RemoteImage.pixelSize(forPointSize: CGSize(width: 100, height: 50), scale: 1)
        #expect(sd.width == 104 && sd.height == 56)
        // Zero input never produces a loadable key.
        let url = try #require(URL(string: "https://example.com/a.jpg"))
        #expect(ImagePipeline.key(
            url: url, pixelSize: .zero, fitting: .fill, blurRadius: 0
        ) == nil)
    }

    @Test func keyBucketsCollapseNearbySizes() throws {
        // 300×450 px and 304×456 px must share one cache entry (bucketed to 320×512).
        let a = try makeKey("https://example.com/p.jpg", 300, 450, .fill)
        let b = try makeKey("https://example.com/p.jpg", 304, 456, .fill)
        #expect(a == b)
        #expect(a.width == 320 && a.height == 512)
        // Blur requests collapse to the fixed 96 px blurred variant.
        let blur = try makeKey("https://example.com/p.jpg", 999, 999, .fill, blur: 24)
        #expect(blur.width == 96 && blur.height == 96 && blur.blur == 24)
        // Different fittings never share an entry.
        let fit = try makeKey("https://example.com/p.jpg", 300, 450, .fit)
        #expect(fit != a)
    }

    // MARK: Placeholder palette memoization

    @Test func placeholderPaletteIsDeterministicPerSeed() {
        let a = PlaceholderArtwork.Palette(seed: "Dune")
        let b = PlaceholderArtwork.Palette(seed: "Dune")
        let c = PlaceholderArtwork.Palette(seed: "Severance")
        #expect(a.gradient == b.gradient)
        #expect(a.glowCenter == b.glowCenter)
        #expect(a.gradient != c.gradient || a.glowCenter != c.glowCenter)
    }
}
