import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Synchronous ImageIO work runs in the pipeline's bounded decode queue.
nonisolated enum ImageDecoder {
    /// Returns `true` when `data` looks like an image ImageIO can decode.
    static func isDecodable(_ data: Data) -> Bool {
        guard data.count > 16,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) != nil,
              CGImageSourceGetCount(source) > 0 else { return false }
        return true
    }

    /// Decodes and downsamples `data` so the result covers (`fill`) or fits in (`fit`) `target` pixels.
    static func decode(
        _ data: Data, target: CGSize, fitting: ImagePipeline.Fitting, fillsForBlur: Bool
    ) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source, target: target, fitting: fitting, fillsForBlur: fillsForBlur)
    }

    /// Reads straight from a local file.
    static func decode(
        fileURL: URL, target: CGSize, fitting: ImagePipeline.Fitting, fillsForBlur: Bool
    ) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(source, target: target, fitting: fitting, fillsForBlur: fillsForBlur)
    }

    private static func thumbnail(
        _ source: CGImageSource, target: CGSize, fitting: ImagePipeline.Fitting, fillsForBlur: Bool
    ) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        var maxPixel = max(target.width, target.height)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0, target.width > 0, target.height > 0 {
            var w = width, h = height
            if let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(orientation) {
                swap(&w, &h)
            }
            guard fitting.acceptsSource(width: w, height: h) else { return nil }
            let fill = fitting.fillsTarget || fillsForBlur
            let scale = fill ? max(target.width / w, target.height / h) : min(target.width / w, target.height / h)
            maxPixel = min(max(w, h), (max(w, h) * scale).rounded(.up))
        } else if fitting.needsSourceDimensions {
            return nil
        }
        // Filling with an unusually wide or tall source can otherwise decode far beyond the slot.
        let decodeLimit: CGFloat = fillsForBlur ? 384 : 4_096
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(min(decodeLimit, maxPixel))),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Gaussian-blurred copy (computed on a small version of the image; meant to be upscaled).
    static func blurred(_ image: CGImage, radius: CGFloat, target: CGSize? = nil) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let scale = target.map { min(max($0.width / width, $0.height / height), 384 / max(width, height), 1) } ?? 1
        let pixelWidth = max(1, Int((width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((height * scale).rounded(.up)))
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        func makeContext() -> CGContext? {
            CGContext(
                data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        guard let source = makeContext(), let destination = makeContext() else { return nil }
        source.interpolationQuality = .medium
        source.draw(image, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        func buffer(_ context: CGContext) -> vImage_Buffer {
            vImage_Buffer(data: context.data, height: vImagePixelCount(pixelHeight), width: vImagePixelCount(pixelWidth), rowBytes: context.bytesPerRow)
        }
        var input = buffer(source), output = buffer(destination)
        // Three box passes approximate the Gaussian on the tiny thumbnail while keeping its pixels
        // off the GPU. The first draw preserves alpha for artwork with transparent edges.
        let boxWidth = UInt32((radius * 2).rounded()) | 1
        let flags = vImage_Flags(kvImageEdgeExtend | kvImageDoNotTile)
        for _ in 0..<3 {
            guard vImageBoxConvolve_ARGB8888(&input, &output, nil, 0, 0, boxWidth, boxWidth, nil, flags) == kvImageNoError else {
                return nil
            }
            swap(&input, &output)
        }
        return destination.makeImage()
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
