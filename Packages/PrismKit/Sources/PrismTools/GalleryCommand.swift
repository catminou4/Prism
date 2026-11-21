import AppKit
import Foundation
import PrismDesign
import SwiftUI

/// `prism-tools gallery <outputDir> [page…]`
enum GalleryCommand {
    static func run(_ arguments: [String]) -> Int32 {
        guard let path = arguments.first else {
            print("usage: prism-tools gallery <outputDir> [page…]")
            return 1
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let filter = Set(arguments.dropFirst())
        let assets = GalleryAssets.prepare(in: output.appending(path: "_assets", directoryHint: .isDirectory))
        var count = 0
        for page in GalleryPages.all(assets: assets) where filter.isEmpty || filter.contains(page.name) {
            prewarm(page.prewarm)
            for scheme in page.schemes {
                let name = "\(page.name)-\(scheme == .dark ? "dark" : "light")"
                if let url = SnapshotRenderer.write(page.view(), size: page.size, colorScheme: scheme, to: output, name: name, settle: page.settle, backend: page.backend) {
                    print("wrote \(url.path)")
                    count += 1
                }
            }
        }
        print("\(count) PNG(s) in \(output.path)")
        return 0
    }
}

extension GalleryCommand {
    /// Loads images into the shared memory cache with `RemoteImage`'s keys, so renderers that
    /// cannot wait for `.task` (ImageRenderer) still show artwork.
    static func prewarm(_ slots: [(url: URL, size: CGSize)]) {
        guard !slots.isEmpty else { return }
        var done = false
        Task {
            for slot in slots {
                let pixels = RemoteImage.pixelSize(forPointSize: slot.size, scale: 2)
                _ = await ImagePipeline.shared.image(for: slot.url, pixelSize: pixels, fitting: .fill)
            }
            done = true
        }
        SnapshotRenderer.spin(until: { done }, timeout: 10)
    }
}

struct GalleryPage {
    let name: String
    let size: CGSize
    var schemes: [ColorScheme] = [.dark, .light]
    var settle: TimeInterval = 1.2
    /// `.imageRenderer` renders blurs/filters faithfully but no AppKit-backed views (ScrollView).
    var backend: SnapshotRenderer.Backend = .window
    /// Images to load before rendering (URL + point size of the `RemoteImage` slot).
    var prewarm: [(url: URL, size: CGSize)] = []
    let view: () -> AnyView
}
