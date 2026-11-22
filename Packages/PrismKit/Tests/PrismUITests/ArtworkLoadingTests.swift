import CoreGraphics
import Foundation
import Testing
@testable import PrismDesign

@Suite("Chargement des visuels")
struct ArtworkLoadingTests {
    private func resolve(_ string: String, _ width: CGFloat, _ height: CGFloat, _ fitting: ImagePipeline.Fitting = .fill) -> ArtworkURL.Resolved {
        ArtworkURL.resolve(URL(string: string)!, target: CGSize(width: width, height: height), fitting: fitting, fillsForBlur: false)
    }

    @Test func tmdbPostersAreRequestedAtTheirDisplaySize() {
        // A 150 pt poster on a Retina screen: 320 × 480 pixel bucket.
        let card = resolve("https://image.tmdb.org/t/p/w600_and_h900_bestv2/abc.jpg", 320, 480)
        #expect(card.primary.absoluteString == "https://image.tmdb.org/t/p/w342/abc.jpg")
        #expect(card.fallback?.absoluteString == "https://image.tmdb.org/t/p/w600_and_h900_bestv2/abc.jpg")
        #expect(card.fallbackIsLarger, "bytes already cached for the provider URL are reused")
        #expect(!card.isOriginal)

        let original = resolve("https://image.tmdb.org/t/p/original/abc.jpg", 384, 576)
        #expect(original.primary.absoluteString == "https://image.tmdb.org/t/p/w500/abc.jpg")

        // A small provider size is upgraded rather than stretched; its cached copy is too small.
        let tiny = resolve("https://image.tmdb.org/t/p/w154/abc.jpg", 320, 480)
        #expect(tiny.primary.absoluteString == "https://image.tmdb.org/t/p/w342/abc.jpg")
        #expect(!tiny.fallbackIsLarger)

        // The legacy host is served by the same CDN.
        let legacy = resolve("https://www.themoviedb.org/t/p/w600_and_h900_bestv2/abc.jpg", 320, 480)
        #expect(legacy.primary.absoluteString == "https://image.tmdb.org/t/p/w342/abc.jpg")
    }

    @Test func heroBackdropsKeepFullResolutionWithAPreview() {
        let hero = resolve("https://image.tmdb.org/t/p/original/back.jpg", 3072, 1024, .landscapeFill)
        #expect(hero.primary.absoluteString == "https://image.tmdb.org/t/p/original/back.jpg")
        #expect(hero.fallback == nil)
        #expect(hero.isOriginal)

        let key = ImagePipeline.key(
            url: URL(string: "https://image.tmdb.org/t/p/original/back.jpg")!,
            pixelSize: CGSize(width: 2880, height: 990), fitting: .landscapeFill, blurRadius: 0
        )!
        let preview = ImagePipeline.previewKey(for: key)
        #expect(preview?.width == 1280)
        #expect(preview.map { ArtworkURL.resolve($0.url, target: $0.target, fitting: $0.fitting, fillsForBlur: false).primary.absoluteString }
                == "https://image.tmdb.org/t/p/w1280/back.jpg")

        // A wide card does not need the original.
        let card = resolve("https://image.tmdb.org/t/p/original/back.jpg", 640, 384, .fill)
        #expect(card.primary.absoluteString == "https://image.tmdb.org/t/p/w780/back.jpg")
        // Provider artwork has no size variants: untouched, and no preview.
        let provider = URL(string: "http://203.0.113.4/images/poster.jpg")!
        #expect(resolve(provider.absoluteString, 3072, 1024, .landscapeFill).primary == provider)
        #expect(ImagePipeline.previewKey(for: ImagePipeline.key(url: provider, pixelSize: CGSize(width: 2880, height: 990), fitting: .landscapeFill, blurRadius: 0)!) == nil)
    }

    @Test func unknownTmdbShapesAreLeftAlone() {
        for string in [
            "https://image.tmdb.org/t/p/w1920_and_h800_multi_faces/abc.jpg",
            "https://image.tmdb.org/t/p/h632/abc.jpg",
            "https://image.tmdb.org/abc.jpg",
            "https://image.tmdb.org/t/p/w500/abc.jpg?x=1",
        ] {
            #expect(resolve(string, 320, 480).primary.absoluteString == string)
        }
    }

    @Test func diskCacheRoundTripsAndTrimsToCapacity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ImageDiskCache(directory: directory, capacity: 64 << 10)
        let payload = Data(repeating: 7, count: 20 << 10)
        for index in 0..<6 {
            cache.store(payload, for: URL(string: "https://example.com/\(index).jpg")!)
        }
        #expect(cache.data(for: URL(string: "https://example.com/5.jpg")!) == payload)
        #expect(cache.data(for: URL(string: "https://example.com/missing.jpg")!) == nil)
        #expect(ImageDiskCache.key(for: URL(string: "https://example.com/5.jpg")!).count == 64)

        cache.trim()
        let remaining = (0..<6).filter { cache.data(for: URL(string: "https://example.com/\($0).jpg")!) != nil }
        #expect(remaining.count * (20 << 10) <= 64 << 10)
        #expect(!remaining.isEmpty)
    }
}
