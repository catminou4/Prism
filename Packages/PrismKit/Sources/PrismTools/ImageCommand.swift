import CoreGraphics
import Foundation
import PrismDesign

/// `prism-tools image <url> [maxPixelSize]`: loads one image through `ImagePipeline`
/// (network → disk cache → ImageIO downsampling) and prints timings, size and average colour.
enum ImageCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let string = arguments.first, let url = URL(string: string) ?? URL(fileURLWithPath: string) as URL? else {
            print("usage: prism-tools image <url> [maxPixelSize]")
            return 1
        }
        let maxPixel = arguments.count > 1 ? (Double(arguments[1]) ?? 400) : 400
        var finished = false
        var status: Int32 = 0
        Task {
            let pipeline = ImagePipeline.shared
            let start = Date()
            let image = await pipeline.image(for: url, maxPixelSize: maxPixel)
            let first = Date().timeIntervalSince(start)
            pipeline.purgeMemory()
            let start2 = Date()
            _ = await pipeline.image(for: url, maxPixelSize: maxPixel)
            let second = Date().timeIntervalSince(start2)
            let start3 = Date()
            _ = await pipeline.image(for: url, maxPixelSize: maxPixel)
            let third = Date().timeIntervalSince(start3)
            if let image {
                let color = await pipeline.averageRGBA(for: url)
                print("decoded \(image.width)×\(image.height) px")
                print(String(format: "first load %.0f ms · disk hit %.0f ms · memory hit %.2f ms", first * 1000, second * 1000, third * 1000))
                if let color {
                    print(String(format: "average colour rgb(%.2f, %.2f, %.2f) sat %.2f", color.red, color.green, color.blue, color.saturation))
                }
            } else {
                print("no image (failed, not an image, or timed out)")
                status = 2
            }
            finished = true
        }
        SnapshotRenderer.spin(until: { finished }, timeout: 30)
        return status
    }
}
