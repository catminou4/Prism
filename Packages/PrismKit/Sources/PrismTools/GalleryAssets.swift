import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI

/// Local artwork for the gallery: crops of the (gitignored) Apple TV reference captures when
/// present, so cards can be compared with real imagery. Falls back to `nil` (placeholders).
struct GalleryAssets {
    var posters: [URL] = []
    var stills: [URL] = []
    var wides: [URL] = []
    var backdrop: URL?
    var portrait: URL?
    var logo: URL?

    /// A transparent "title logo" PNG (like TMDB logos) to exercise `TitleLogo`.
    static func renderLogo(in directory: URL) -> URL? {
        let renderer = ImageRenderer(content:
            Text("SEVERANCE")
                .font(.system(size: 96, weight: .heavy).width(.expanded))
                .tracking(-2)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
        )
        renderer.scale = 1
        renderer.isOpaque = false
        guard let image = renderer.cgImage, let data = SnapshotRenderer.png(from: image) else { return nil }
        let url = directory.appending(path: "logo.png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    /// Walks up from the source file (symlinks resolved) and the working directory to find
    /// `design/references-appletv-mac`.
    static func referencesDirectory() -> URL? {
        let starts = [
            URL(fileURLWithPath: #filePath).resolvingSymlinksInPath().deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        ]
        for start in starts {
            var directory = start
            for _ in 0..<8 {
                let candidate = directory.appending(path: "design/references-appletv-mac", directoryHint: .isDirectory)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
                directory = directory.deletingLastPathComponent()
            }
        }
        return nil
    }

    static func prepare(in directory: URL) -> GalleryAssets {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var assets = GalleryAssets()
        assets.logo = renderLogo(in: directory)
        guard let references = referencesDirectory() else {
            print("note: design/references-appletv-mac not found — gallery uses placeholders only")
            return assets
        }
        func crop(_ file: String, _ rect: CGRect, _ name: String) -> URL? {
            let source = references.appending(path: file)
            guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let cropped = image.cropping(to: rect) else { return nil }
            let url = directory.appending(path: "\(name).png")
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cropped, nil)
            return CGImageDestinationFinalize(dest) ? url : nil
        }
        // 13_appletv_s1.png: "Must-See Hits" posters (2:3, 274×408 px each, 314 px pitch).
        for i in 0..<6 {
            if let url = crop("13_appletv_s1.png", CGRect(x: 524 + i * 314, y: 410, width: 266, height: 400), "poster\(i)") {
                assets.posters.append(url)
            }
        }
        // 23_show2_s1.png: episode stills (sharp top part of each 430 px card, 470 px pitch).
        for i in 0..<4 {
            if let url = crop("23_show2_s1.png", CGRect(x: 524 + i * 470, y: 250, width: 422, height: 196), "still\(i)") {
                assets.stills.append(url)
            }
        }
        // 03_home.png: Continue Watching artwork (16:9 part of each card).
        for i in 0..<4 {
            if let url = crop("03_home.png", CGRect(x: 524 + i * 470, y: 887, width: 422, height: 236), "wide\(i)") {
                assets.wides.append(url)
            }
        }
        // 14_store_top.png: hero backdrop (right part, no text).
        assets.backdrop = crop("14_store_top.png", CGRect(x: 1100, y: 0, width: 1300, height: 1000), "backdrop")
        // 07_show_s1.png: first cast portrait.
        assets.portrait = crop("07_show_s1.png", CGRect(x: 530, y: 248, width: 176, height: 176), "portrait")
        return assets
    }
}
