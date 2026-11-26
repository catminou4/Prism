import AppKit
import PrismCore
import PrismData
@testable import PrismDesign
import QuartzCore
import SwiftUI
import Synchronization
import Testing
@testable import PrismUI

/// Self-referential pixel comparison of placeholder rendering candidates. Both trees are
/// rendered through the same offscreen `cacheDisplay` pipeline in one process, so any
/// machine-dependent rendering behavior affects both equally: the comparison isolates
/// the structural difference. Run with PRISM_PIXEL_PROBE=1 while candidates are evaluated.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_PIXEL_PROBE"] == "1"))
struct PlaceholderPixelTests {
    /// Renders the production placeholder and candidate trees for a matrix of seeds and
    /// card sizes, then byte-compares the bitmaps. Any mismatch reports the first differing
    /// pixel position and values. Candidates: production ZStack, flattened overlay chain,
    /// Canvas, per-seed pre-rendered bitmap.
    @Test func candidates() async throws {
        _ = NSApplication.shared
        let seeds = ["Film 0", "Film 1", "Dune : Deuxième partie", "Slow Horses", "A", "éèê unicode"]
        let sizes = [
            CGSize(width: 138, height: 207),
            CGSize(width: 150, height: 225),
            CGSize(width: 260, height: 146),
        ]
        var report: [String] = []
        for seed in seeds {
            for size in sizes {
                let reference = render(
                    PlaceholderArtwork(seed: seed)
                        .frame(width: size.width, height: size.height),
                    size: size
                )
                let flattened = render(
                    ProbeFlattened(seed: seed)
                        .frame(width: size.width, height: size.height),
                    size: size
                )
                let canvas = render(
                    ProbeCanvas(seed: seed)
                        .frame(width: size.width, height: size.height),
                    size: size
                )
                let bitmap = render(
                    ProbeBitmap(seed: seed, size: size),
                    size: size
                )
                for (name, candidate) in [("flattened", flattened), ("canvas", canvas), ("bitmap", bitmap)] {
                    let diff = firstDifference(reference, candidate)
                    report.append("\(seed) \(Int(size.width))x\(Int(size.height)) \(name): \(diff ?? "identical")")
                }
            }
        }
        for line in report { print("[pixel] \(line)") }
    }

    /// Same comparison with the title label rendered inside the placeholder (shelf style).
    @Test func withTitles() async throws {
        _ = NSApplication.shared
        let seeds = ["Film 0", "Dune : Deuxième partie"]
        let size = CGSize(width: 138, height: 207)
        for seed in seeds {
            let reference = render(
                PlaceholderArtwork(seed: seed, title: seed)
                    .frame(width: size.width, height: size.height),
                size: size
            )
            let flattened = render(
                ProbeFlattened(seed: seed, title: seed)
                    .frame(width: size.width, height: size.height),
                size: size
            )
            let diff = firstDifference(reference, flattened)
            print("[pixel] titled \(seed) flattened: \(diff ?? "identical")")
        }
    }

    private func render(_ view: some View, size: CGSize) -> [UInt8] {
        let host = NSHostingView(rootView: view
            .environment(\.displayScale, 2)
            .environment(\.colorScheme, .dark))
        let scale: CGFloat = 2
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let frame = CGRect(origin: .zero, size: size)
        host.frame = frame
        let window = NSWindow(
            contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
        guard let bitmapRep = host.bitmapImageRepForCachingDisplay(in: frame) else { return [] }
        host.cacheDisplay(in: frame, to: bitmapRep)
        guard let data = bitmapRep.bitmapData else { return [] }
        let count = Int(pixelSize.width) * Int(pixelSize.height) * 4
        return Array(UnsafeBufferPointer(start: data, count: min(count, bitmapRep.bytesPerRow * bitmapRep.pixelsHigh)))
    }

    private func firstDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> String? {
        guard lhs.count == rhs.count, !lhs.isEmpty else {
            return lhs.count == rhs.count ? nil : "size mismatch \(lhs.count) vs \(rhs.count)"
        }
        var differring = 0
        var first: Int?
        for index in 0..<lhs.count where lhs[index] != rhs[index] {
            differring += 1
            if first == nil { first = index }
        }
        guard let first else { return nil }
        let pixel = first / 4
        return "\(differring) bytes differ, first at pixel (\(pixel % 138), \(pixel / 138)) byte \(first % 4): \(lhs[first]) vs \(rhs[first])"
    }
}

/// The flattened production-equivalent candidate: `linear.overlay { radial }`, label on top.
private struct ProbeFlattened: View {
    let seed: String
    var title: String? = nil
    private let palette: PlaceholderArtwork.Palette

    init(seed: String, title: String? = nil) {
        self.seed = seed
        self.title = title
        palette = PlaceholderArtwork.Palette(seed: seed)
    }

    var body: some View {
        LinearGradient(colors: palette.gradient, startPoint: palette.start, endPoint: palette.end)
            .overlay {
                RadialGradient(colors: [.white.opacity(0.10), .clear], center: palette.glowCenter, startRadius: 0, endRadius: 225)
            }
            .overlay {
                if let title {
                    Text(title)
                        .font(.system(size: 21, weight: .bold))
                        .tracking(-0.3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .minimumScaleFactor(0.5)
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 22)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct ProbeCanvas: View {
    private let palette: PlaceholderArtwork.Palette

    init(seed: String) {
        palette = PlaceholderArtwork.Palette(seed: seed)
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            context.fill(
                Path(rect),
                with: .linearGradient(
                    Gradient(colors: palette.gradient),
                    startPoint: CGPoint(x: palette.start.x * size.width, y: palette.start.y * size.height),
                    endPoint: CGPoint(x: palette.end.x * size.width, y: palette.end.y * size.height)
                )
            )
            context.fill(
                Path(rect),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.10), .clear]),
                    center: CGPoint(x: palette.glowCenter.x * size.width, y: palette.glowCenter.y * size.height),
                    startRadius: 0,
                    endRadius: 225
                )
            )
        }
        .accessibilityHidden(true)
    }
}

/// Bitmap candidate: replicates the CoreGraphics rendering used by the production probe.
private struct ProbeBitmap: View {
    let seed: String
    let size: CGSize

    var body: some View {
        if let image = ProbePixelBitmapCache.image(seed: seed, pointSize: size, scale: 2) {
            Image(decorative: image, scale: 2)
                .frame(width: size.width, height: size.height)
                .accessibilityHidden(true)
        }
    }
}

enum ProbePixelBitmapCache {
    private struct Key: Hashable {
        let seed: String
        let width: Int
        let height: Int
    }

    private static let storage = Mutex<[Key: CGImage]>([:])

    static func image(seed: String, pointSize: CGSize, scale: CGFloat) -> CGImage? {
        let pixelWidth = Int((pointSize.width * scale).rounded(.up))
        let pixelHeight = Int((pointSize.height * scale).rounded(.up))
        let key = Key(seed: seed, width: pixelWidth, height: pixelHeight)
        if let hit = storage.withLock({ $0[key] }) { return hit }
        guard let image = render(seed: seed, pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale) else { return nil }
        storage.withLock { $0[key] = image }
        return image
    }

    private static func render(seed: String, pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> CGImage? {
        let palette = PlaceholderArtwork.Palette(seed: seed)
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let size = CGSize(width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        var rng = StableHash.Generator(seed: seed)
        let topW = 0.12 + rng.unit() * 0.19
        let bottomW = 0.045 + rng.unit() * 0.045

        let linearColors: [CGFloat] = [topW, topW, topW, 1, bottomW, bottomW, bottomW, 1]
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let gradient = CGGradient(colorSpace: space, colorComponents: linearColors, locations: [0, 1], count: 2) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: palette.start.x * size.width, y: palette.start.y * size.height),
                end: CGPoint(x: palette.end.x * size.width, y: palette.end.y * size.height),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        let glowColors: [CGFloat] = [1, 1, 1, 0.10, 1, 1, 1, 0]
        if let glow = CGGradient(colorSpace: space, colorComponents: glowColors, locations: [0, 1], count: 2) {
            context.drawRadialGradient(
                glow,
                startCenter: CGPoint(x: palette.glowCenter.x * size.width, y: palette.glowCenter.y * size.height), startRadius: 0,
                endCenter: CGPoint(x: palette.glowCenter.x * size.width, y: palette.glowCenter.y * size.height), endRadius: 225,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
        return context.makeImage()
    }
}
