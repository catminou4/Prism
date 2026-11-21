import AppKit
import Foundation
import QuartzCore
import SwiftUI

@testable import PrismPlayer

/// Offscreen SwiftUI → PNG (borderless window far off-screen, never ordered in; never captures
/// the screen). Liquid Glass is replaced by its snapshot approximation.
enum PlayerSnapshotRenderer {
    static var outputDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PRISM_SNAPSHOT_DIR"] {
            return URL(fileURLWithPath: override)
        }
        // …/Packages/PrismKit/Tests/PrismPlayerTests/<file> → repo root/Tools/output/player
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Tools/output/player")
    }

    @discardableResult
    static func write(_ view: some View, size: CGSize, name: String, scale: CGFloat = 2) throws -> URL {
        _ = NSApplication.shared
        let root = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark)
            .environment(\.playerSnapshotRendering, true)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        spin(0.5)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        CATransaction.flush()

        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard let layer = hosting.layer,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw SnapshotError.context }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        layer.render(in: context)
        window.contentView = nil
        window.close()
        guard let image = context.makeImage(),
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw SnapshotError.encode }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appending(path: "\(name).png")
        try data.write(to: url)
        return url
    }

    static func spin(_ duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    enum SnapshotError: Error { case context, encode }
}
