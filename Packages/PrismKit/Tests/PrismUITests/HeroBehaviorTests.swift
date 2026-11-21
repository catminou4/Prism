import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PrismDesign

struct HeroBehaviorTests {
    @Test func horizontalGesturePagesOnceAndConsumesItsMomentum() {
        var gesture = HeroScrollGesture()
        #expect(!gesture.add(horizontal: -3, vertical: 1).consumesEvent)
        #expect(gesture.add(horizontal: -11, vertical: 1).consumesEvent)
        #expect(gesture.add(horizontal: -34, vertical: 2).pageOffset == 1)
        #expect(gesture.add(horizontal: -140, vertical: 0).pageOffset == nil)
        #expect(gesture.consumesMomentum)

        gesture = HeroScrollGesture()
        #expect(gesture.add(horizontal: 49, vertical: 4).pageOffset == -1)
    }

    @Test func verticalGesturePassesThroughEvenWithLateHorizontalDrift() {
        var gesture = HeroScrollGesture()
        #expect(!gesture.add(horizontal: -7, vertical: 21).consumesEvent)
        #expect(!gesture.add(horizontal: -85, vertical: 14).consumesEvent)
        #expect(!gesture.consumesMomentum)
    }

    @Test func artworkRejectsMislabelledPortraitsAndRespectsEXIFOrientation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let landscape = try writeImage(at: directory.appending(path: "landscape.jpg"), width: 800, height: 450)
        let portrait = try writeImage(at: directory.appending(path: "portrait.jpg"), width: 450, height: 800)
        let rotated = try writeImage(at: directory.appending(path: "rotated.jpg"), width: 450, height: 800, orientation: 6)
        let small = try writeImage(at: directory.appending(path: "small.jpg"), width: 320, height: 180)
        let pipeline = ImagePipeline(diskDirectory: directory.appending(path: "cache", directoryHint: .isDirectory))
        let target = CGSize(width: 1000, height: 420)

        #expect(await pipeline.image(for: landscape, pixelSize: target, fitting: .landscapeFill) != nil)
        #expect(await pipeline.image(for: portrait, pixelSize: target, fitting: .fill) != nil)
        #expect(await pipeline.image(for: portrait, pixelSize: target, fitting: .landscapeFill) == nil)
        #expect(await pipeline.image(for: small, pixelSize: target, fitting: .landscapeFill) == nil)
        #expect(await pipeline.image(for: portrait, pixelSize: target, fitting: .portraitFit) != nil)
        #expect(await pipeline.image(for: rotated, pixelSize: target, fitting: .landscapeFill) != nil)
        #expect(await pipeline.image(for: rotated, pixelSize: target, fitting: .portraitFit) == nil)
    }

    private func writeImage(at url: URL, width: Int, height: Int, orientation: Int = 1) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return url
    }
}
