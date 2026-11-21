import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SwiftUI

/// ImageIO decoding helpers. Every entry point is `@concurrent` so decoding never runs on
/// the main actor nor serialises on the pipeline actor.
nonisolated enum ImageDecoder {
    /// Shared Core Image context (thread-safe).
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Returns `true` when `data` looks like an image ImageIO can decode.
    static func isDecodable(_ data: Data) -> Bool {
        guard data.count > 16,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    /// Decodes and downsamples `data` so the result covers (`fill`) or fits in (`fit`) `target` pixels.
    @concurrent static func decode(_ data: Data, target: CGSize, fill: Bool) async -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source, target: target, fill: fill)
    }

    /// Same as `decode(_:target:fill:)` reading straight from a local file.
    @concurrent static func decode(fileURL: URL, target: CGSize, fill: Bool) async -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source, target: target, fill: fill)
    }

    private static func thumbnail(_ source: CGImageSource, target: CGSize, fill: Bool) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        var maxPixel = max(target.width, target.height)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0, target.width > 0, target.height > 0 {
            var w = width, h = height
            if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, orientation >= 5 {
                swap(&w, &h)
            }
            let scale = fill ? max(target.width / w, target.height / h) : min(target.width / w, target.height / h)
            maxPixel = min(max(w, h), (max(w, h) * scale).rounded(.up))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixel)),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Gaussian-blurred copy (computed on a small version of the image; meant to be upscaled).
    @concurrent static func blurred(_ image: CGImage, radius: CGFloat) async -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: Double(radius)).cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent)
    }

    /// Alpha-weighted average colour with a light vibrance boost (muddy averages look dull).
    @concurrent static func averageColor(of image: CGImage) async -> RGBA? {
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.4 else { continue }
            let pr = Double(pixels[i]) / 255 / a, pg = Double(pixels[i + 1]) / 255 / a, pb = Double(pixels[i + 2]) / 255 / a
            let maxC = max(pr, pg, pb), minC = min(pr, pg, pb)
            // Favour saturated pixels so a logo's brand colour wins over its white/black parts.
            let weight = a * (0.15 + (maxC - minC))
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }
        return RGBA(red: r / total, green: g / total, blue: b / total, alpha: 1).boostingVibrance()
    }
}

/// Plain sendable colour value (sRGB 0…1).
nonisolated public struct RGBA: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public nonisolated init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    public nonisolated var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    /// Perceived luminance (Rec. 709).
    public nonisolated var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    public nonisolated var saturation: Double {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        return maxC == 0 ? 0 : (maxC - minC) / maxC
    }

    nonisolated func boostingVibrance(_ amount: Double = 0.25) -> RGBA {
        let mean = (red + green + blue) / 3
        func push(_ c: Double) -> Double { min(1, max(0, c + (c - mean) * amount)) }
        return RGBA(red: push(red), green: push(green), blue: push(blue), alpha: alpha)
    }

    /// Scales brightness (HSB value) keeping hue/saturation.
    public nonisolated func scaled(brightness factor: Double) -> RGBA {
        RGBA(red: min(1, red * factor), green: min(1, green * factor), blue: min(1, blue * factor), alpha: alpha)
    }
}
