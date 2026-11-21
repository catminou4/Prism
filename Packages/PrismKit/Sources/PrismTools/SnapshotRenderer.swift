import AppKit
import QuartzCore
import Foundation
import PrismDesign
import SwiftUI

/// Offscreen SwiftUI → PNG rendering (never touches the visible screen).
///
/// Hosts the view in an `NSHostingView` inside a borderless window placed far off-screen
/// (never ordered in), lets the run loop settle (async image loads, `.task`), then draws the
/// view hierarchy into a bitmap at `scale`. Liquid Glass / materials may render flat.
enum SnapshotRenderer {
    enum Backend {
        /// `NSHostingView` + `cacheDisplay` — supports AppKit-backed views (ScrollView, menus…).
        case window
        /// `ImageRenderer` — pure SwiftUI only.
        case imageRenderer
    }

    /// Renders `view` at `size` points and returns PNG data.
    static func render(
        _ view: some View,
        size: CGSize,
        colorScheme: ColorScheme,
        scale: CGFloat = 2,
        settle: TimeInterval = 0.6,
        backend: Backend = .window
    ) -> Data? {
        let root = view
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme)
            .environment(\.prismSnapshotRendering, true)
        switch backend {
        case .window:
            return renderInWindow(root, size: size, colorScheme: colorScheme, scale: scale, settle: settle)
        case .imageRenderer:
            let renderer = ImageRenderer(content: root.background(colorScheme == .dark ? Color.black : Color.white))
            renderer.scale = scale
            renderer.proposedSize = ProposedViewSize(size)
            spin(for: settle)
            guard let image = renderer.cgImage else { return nil }
            return png(from: image)
        }
    }

    /// Renders and writes `name.png` into `directory`. Returns the written URL.
    @discardableResult
    static func write(
        _ view: some View,
        size: CGSize,
        colorScheme: ColorScheme,
        to directory: URL,
        name: String,
        scale: CGFloat = 2,
        settle: TimeInterval = 0.6,
        backend: Backend = .window
    ) -> URL? {
        guard let data = render(view, size: size, colorScheme: colorScheme, scale: scale, settle: settle, backend: backend) else {
            FileHandle.standardError.write(Data("render failed: \(name)\n".utf8))
            return nil
        }
        let url = directory.appending(path: "\(name).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            FileHandle.standardError.write(Data("write failed: \(url.path) \(error)\n".utf8))
            return nil
        }
    }

    /// Runs the main run loop (drains main-actor tasks) for `duration` seconds.
    static func spin(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.02)))
        }
    }

    /// Runs the run loop until `condition` is true or `timeout` elapses.
    static func spin(until condition: () -> Bool, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func renderInWindow(_ view: some View, size: CGSize, colorScheme: ColorScheme, scale: CGFloat, settle: TimeInterval) -> Data? {
        let rect = NSRect(origin: .zero, size: size)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = rect
        hosting.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window.backgroundColor = colorScheme == .dark ? .black : .white
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        spin(for: settle)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()

        let pixelsWide = Int(size.width * scale), pixelsHigh = Int(size.height * scale)
        guard let layer = hosting.layer,
              let context = CGContext(
                  data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        // Opaque page colour first (window background is not part of the layer tree).
        context.setFillColor(colorScheme == .dark ? CGColor(gray: 0, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        context.scaleBy(x: scale, y: scale)
        // `render(in:)` draws in layer (top-left) coordinates: flip to CG's bottom-left origin.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        CATransaction.flush()
        if ProcessInfo.processInfo.environment["PRISM_DUMP_LAYERS"] != nil { dump(layer, depth: 0) }
        layer.render(in: context)
        window.contentView = nil
        window.close()
        guard let image = context.makeImage() else { return nil }
        return png(from: image)
    }

    private static func dump(_ layer: CALayer, depth: Int) {
        let pad = String(repeating: "  ", count: depth)
        print("\(pad)\(type(of: layer)) frame=\(layer.frame) contents=\(layer.contents != nil) bg=\(layer.backgroundColor.map { String(describing: $0.components ?? []) } ?? "-") cs=\(layer.compositingFilter.map { String(describing: $0) } ?? "-") mask=\(layer.mask != nil) hidden=\(layer.isHidden) opacity=\(layer.opacity) filters=\(layer.filters?.count ?? 0) flipped=\(layer.isGeometryFlipped)")
        for sub in layer.sublayers ?? [] { dump(sub, depth: depth + 1) }
    }

    static func png(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
