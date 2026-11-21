import AppKit
import Foundation
import PrismDesign
import SwiftUI

/// `prism-tools icon <appiconsetDir>`: renders `AppIconArtwork` natively at every macOS icon
/// size (vector, so small sizes stay crisp) and rewrites `Contents.json` with the file names.
enum IconCommand {
    struct Slot {
        let points: Int
        let scale: Int
        var pixels: Int { points * scale }
        var filename: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
    }

    static let slots: [Slot] = [16, 32, 128, 256, 512].flatMap { [Slot(points: $0, scale: 1), Slot(points: $0, scale: 2)] }

    static func run(_ arguments: [String]) -> Int32 {
        guard let path = arguments.first else {
            print("usage: prism-tools icon <appiconsetDir>")
            return 1
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for slot in slots {
            let renderer = ImageRenderer(content: AppIconArtwork(size: CGFloat(slot.pixels)))
            renderer.scale = 1
            renderer.isOpaque = false
            guard let image = renderer.cgImage, let data = SnapshotRenderer.png(from: image) else {
                FileHandle.standardError.write(Data("failed to render \(slot.filename)\n".utf8))
                return 1
            }
            do {
                try data.write(to: directory.appending(path: slot.filename))
                print("wrote \(slot.filename) (\(image.width)×\(image.height))")
            } catch {
                FileHandle.standardError.write(Data("write failed \(slot.filename): \(error)\n".utf8))
                return 1
            }
        }
        return writeContents(in: directory)
    }

    /// Keeps the existing `Contents.json` layout (one entry per line) and adds `filename`.
    static func writeContents(in directory: URL) -> Int32 {
        let entries = slots.map { slot in
            "    { \"filename\" : \"\(slot.filename)\", \"idiom\" : \"mac\", \"scale\" : \"\(slot.scale)x\", \"size\" : \"\(slot.points)x\(slot.points)\" }"
        }
        let json = "{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
        do {
            try json.write(to: directory.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
            print("updated Contents.json")
            return 0
        } catch {
            FileHandle.standardError.write(Data("Contents.json write failed: \(error)\n".utf8))
            return 1
        }
    }
}
