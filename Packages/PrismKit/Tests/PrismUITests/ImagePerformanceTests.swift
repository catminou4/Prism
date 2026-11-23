import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import PrismDesign

/// Run in Release with PRISM_IMAGE_PERF=1. Prints timings; asserts only correctness.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_IMAGE_PERF"] == "1"))
struct ImagePerformanceTests {
    /// Steady-state browsing: the memory cache is full and every newly decoded poster evicts.
    /// Inserts hold the same lock `RemoteImage.body` takes for its synchronous lookup.
    @Test func memoryCacheSteadyStateInserts() throws {
        let context = try #require(CGContext(
            data: nil, width: 320, height: 512, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let poster = try #require(context.makeImage())
        let small = try #require(CGContext(
            data: nil, width: 64, height: 96, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )?.makeImage())
        for (label, image, count) in [("posters 320×512", poster, 3_000), ("logos 64×96", small, 12_000)] {
            let cache = MemoryCache(costLimit: 160 << 20)
            let clock = ContinuousClock()
            var samples: [Double] = []
            samples.reserveCapacity(count)
            for index in 0..<count {
                let key = ImagePipeline.Key(url: URL(string: "https://example.com/\(index).jpg")!, width: image.width,
                                            height: image.height, fitting: .fill, blur: 0)
                let start = clock.now
                cache.insert(image, for: key)
                let elapsed = start.duration(to: clock.now)
                samples.append(Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6)
                #expect(cache.image(for: key) != nil)
            }
            let steady = Array(samples.suffix(count / 2)).sorted()
            let total = steady.reduce(0, +)
            print("[image-perf] MemoryCache \(label): \(count) inserts, steady-state mean \(String(format: "%.2f", total / Double(steady.count))) µs, "
                + "p99 \(String(format: "%.1f", steady[steady.count * 99 / 100])) µs, max \(String(format: "%.1f", steady.last ?? 0)) µs, "
                + "sorting inserts \(steady.count { $0 > 20 })/\(steady.count)")
        }
    }

    /// Decode cost of real cached artwork at card sizes (reads the installed app's image cache
    /// read-only when present; otherwise skipped).
    @Test func decodeCachedArtwork() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers/app.prism.Prism/Data/Library/Caches/Prism/Images")
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        var files: [URL] = []
        for case let url as URL in enumerator where files.count < 400 {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
        }
        guard !files.isEmpty else { return }
        let datas = files.compactMap { try? Data(contentsOf: $0) }.filter(ImageDecoder.isDecodable)
        let clock = ContinuousClock()
        var byType: [String: [Data]] = [:]
        for data in datas {
            let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).map { $0 as String } ?? "?"
            byType[type, default: []].append(data)
        }
        for (type, group) in byType.sorted(by: { $0.key < $1.key }) {
            let start = clock.now
            for data in group { _ = ImageDecoder.decode(data, target: CGSize(width: 320, height: 512), fitting: .fill, fillsForBlur: false) }
            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
            let bytes = group.reduce(0) { $0 + $1.count } / max(1, group.count)
            print("[image-perf] decode \(type) → 320×512: \(group.count) images, \(String(format: "%.2f", ms / Double(group.count))) ms/image, \(bytes / 1024) KB avg")
        }
        for (label, target, fitting) in [("poster 304×456 fill", CGSize(width: 320, height: 512), ImagePipeline.Fitting.fill),
                                         ("wide 520×292 fill", CGSize(width: 640, height: 320), .fill)] {
            let start = clock.now
            var decoded = 0
            for data in datas where ImageDecoder.decode(data, target: target, fitting: fitting, fillsForBlur: false) != nil { decoded += 1 }
            let elapsed = start.duration(to: clock.now)
            let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1e3
            print("[image-perf] decode \(label): \(decoded)/\(datas.count) images, \(String(format: "%.2f", ms / Double(max(1, datas.count)))) ms/image")
        }
    }
}
