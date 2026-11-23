import AppKit
import Darwin
import ImageIO
import PrismCore
import PrismData
import PrismDesign
import QuartzCore
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import PrismUI

/// Run in Release with PRISM_SCROLL_PERF=1. The window is never ordered onscreen.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_SCROLL_PERF"] == "1"))
struct ScrollPerformanceTests {
    @Test func homeFeed() async throws {
        _ = NSApplication.shared
        let model = AppModel(directories: .temporary("prism-home-scroll-bench"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        for try await _ in model.importDemo() {}
        await model.refreshFeed(model.curationRequest(for: .home))
        #expect(!model.feed(for: .home).highlights.isEmpty)

        let frame = CGRect(x: 0, y: 0, width: 1_660, height: 960)
        let host = NSHostingView(rootView: LibraryShell().environment(model).frame(width: frame.width, height: frame.height))
        host.frame = frame
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        layout(host)
        try await Task.sleep(for: .milliseconds(700))
        layout(host)

        let scroll = try #require(scrollView(in: host, minimumWidth: 1_000))
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let distance = min(4_800, clip.documentRect.height - clip.bounds.height)
        #expect(distance > 300)

        let direction: CGFloat = clip.isFlipped ? 1 : -1
        let clock = ContinuousClock()
        let start = clock.now
        let steps = 120
        var samples: [Double] = []
        for step in 1...steps {
            try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
            let fraction = CGFloat(min(step, steps - step)) / CGFloat(steps / 2)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * distance * fraction)
            let sampleStart = clock.now
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            layout(host)
            samples.append(milliseconds(sampleStart.duration(to: clock.now)))
            if step == steps / 2 { #expect(abs(clip.bounds.origin.y - origin.y) > 300) }
        }
        let sorted = samples.sorted()
        print("[scroll-perf] Home: p50 \(format(sorted[steps / 2 - 1])) ms, p95 \(format(sorted[steps * 95 / 100 - 1])) ms, "
            + "max \(format(sorted[steps - 1])) ms, \(samples.count { $0 > 1_000.0 / 120 })/\(steps) over 8.33 ms")
    }

    @Test func browseShelves() async throws {
        try await measureShelves()
    }

    @Test func fastScrollWithColdArtwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "prism-scroll-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try #require(CGContext(
            data: nil, width: 600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))

        let posters = try (0..<360).map { index in
            let url = directory.appending(path: "\(index).jpg")
            try (data as Data).write(to: url)
            return url
        }
        try await measureShelves(posters: posters)
    }

    private func measureShelves(posters: [URL] = []) async throws {
        _ = NSApplication.shared
        let activity = ScrollActivity()
        activity.update(isScrolling: true)
        let titles = (0..<360).map { index in
            MediaTitle(id: TitleID(rawValue: "movie:\(index)"), kind: .movie,
                       title: "Film \(index)", year: 2000 + index % 25, variants: [],
                       posterURL: posters.isEmpty ? nil : posters[index])
        }
        let model = AppModel(directories: .temporary("prism-shelves-bench"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: ScrollView {
            LazyVStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
                ForEach(0..<20) { index in
                    TitleShelf(title: "Sélection \(index)", items: Array(titles[(index * 18)..<(index * 18 + 18)]))
                }
            }
        }
        // Programmatic AppKit offsets don't publish a SwiftUI scroll phase.
        .environment(\.prismScrollActivity, activity)
        .environment(\.displayScale, 2)
        .frame(width: size.width, height: size.height)
            .environment(\.prismShelfViewportWidth, size.width)
            .environment(model).environment(navigation))
        host.frame = frame
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        layout(host)
        let scroll = try #require(scrollView(in: host))
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let direction: CGFloat = clip.isFlipped ? 1 : -1
        try await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let start = clock.now
        let steps = posters.isEmpty ? 240 : 120
        let pointsPerStep = posters.isEmpty ? 24 : 88
        var samples: [Double] = []
        for step in 1...steps {
            try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
            let offset = min(step, steps - step)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * pointsPerStep))
            let sampleStart = clock.now
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            layout(host)
            samples.append(milliseconds(sampleStart.duration(to: clock.now)))
            if step == steps / 2 { #expect(abs(clip.bounds.origin.y - destination.y) < 1) }
        }
        let sorted = samples.sorted()
        let wall = milliseconds(start.duration(to: clock.now))
        let kind = posters.isEmpty ? "placeholders" : "cold artwork, \(pointsPerStep) pt/step"
        print("[scroll-perf] 20 shelves × 18 posters (\(kind)): p50 \(format(sorted[steps / 2 - 1])) ms, "
            + "p95 \(format(sorted[steps * 95 / 100 - 1])) ms, max \(format(sorted[steps - 1])) ms, "
            + "\(samples.count { $0 > 1_000.0 / 120 })/\(steps) over 8.33 ms, wall \(format(wall)) ms")
        print("[scroll-perf] slow steps: \(samples.enumerated().filter { $0.element > 1_000.0 / 120 }.map { "\($0.offset + 1):\(format($0.element))" }.joined(separator: ", "))")

        if let poster = posters.first {
            let width = PrismMetrics.columnWidth(available: size.width - PrismMetrics.contentMargin * 2, minWidth: PrismMetrics.posterMinWidth)
            let pixels = RemoteImage.pixelSize(forPointSize: CGSize(width: width, height: (width / PrismMetrics.posterAspectRatio).rounded()), scale: 2)
            #expect(ImagePipeline.shared.cachedImage(for: poster, pixelSize: pixels) == nil)
            activity.update(isScrolling: false)
            let deadline = clock.now.advanced(by: .seconds(2))
            while ImagePipeline.shared.cachedImage(for: poster, pixelSize: pixels) == nil && clock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                layout(host)
            }
            #expect(ImagePipeline.shared.cachedImage(for: poster, pixelSize: pixels) != nil)
        }
    }

    @Test func titleGrid() async throws {
        _ = NSApplication.shared
        let titles = (0..<100_000).map { index in
            MediaTitle(id: TitleID(rawValue: "movie:\(index)"), kind: .movie,
                       title: "Film \(index)", year: 2000 + index % 25, variants: [])
        }
        let model = AppModel(directories: .temporary("prism-scroll-bench"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)
        let clock = ContinuousClock()
        let startup = clock.now
        let host = NSHostingView(
            rootView: ScrollView {
                TitleGrid(items: titles, availableWidth: size.width)
            }
            .environment(\.prismIsScrollingContent, true)
            .frame(width: size.width, height: size.height)
            .environment(model)
            .environment(navigation)
        )
        host.frame = frame
        let window = NSWindow(contentRect: frame.offsetBy(dx: -20_000, dy: -20_000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        layout(host)
        let startupMS = milliseconds(startup.duration(to: clock.now))
        let scroll = try #require(scrollView(in: host))
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let direction: CGFloat = clip.isFlipped ? 1 : -1
        try await Task.sleep(for: .milliseconds(100))
        let steps = 240
        let interval: Duration = .nanoseconds(8_333_333)
        var samples: [Double] = []
        let startUsage = usage()
        let startEnergy = energy()
        let scrollStart = clock.now
        for step in 1...steps {
            try await clock.sleep(until: scrollStart.advanced(by: interval * step))
            let offset = min(step, steps - step)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 48))
            let start = clock.now
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            layout(host)
            samples.append(milliseconds(start.duration(to: clock.now)))
            if step == steps / 2 { #expect(abs(clip.bounds.origin.y - destination.y) < 1) }
        }
        let wallSeconds = milliseconds(scrollStart.duration(to: clock.now)) / 1_000
        let endEnergy = energy()
        let endUsage = usage()
        let sorted = samples.sorted()
        let budget = 1_000.0 / 120
        let overBudget = samples.count { $0 > budget }
        let cpuMS = (cpuSeconds(endUsage) - cpuSeconds(startUsage)) * 1_000
        print("[scroll-perf] 100k posters, \(steps) steps at 48 pt: first layout \(format(startupMS)) ms, "
            + "p50 \(format(sorted[steps / 2 - 1])) ms, p95 \(format(sorted[steps * 95 / 100 - 1])) ms, "
            + "max \(format(sorted[steps - 1])) ms, \(overBudget)/\(steps) over \(format(budget)) ms, "
            + "CPU \(format(cpuMS)) ms, peak RSS \(format(Double(endUsage.ru_maxrss) / 1_048_576)) MiB")
        if let startEnergy, let endEnergy, endEnergy > startEnergy {
            let joules = Double(endEnergy - startEnergy) / 1e9
            print("[scroll-perf] Kernel-attributed process energy \(format(joules)) J, "
                + "\(format(joules / wallSeconds)) W over \(format(wallSeconds)) s")
        }
    }

    private func scrollView(in view: NSView, minimumWidth: CGFloat = 0) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.frame.width >= minimumWidth { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0, minimumWidth: minimumWidth) }.first
    }

    private func layout(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    private func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }

    private func usage() -> rusage {
        var result = rusage()
        getrusage(RUSAGE_SELF, &result)
        return result
    }

    private func energy() -> UInt64? {
        var result = rusage_info_v6()
        let status = withUnsafeMutablePointer(to: &result) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return status == 0 ? result.ri_energy_nj : nil
    }

    private func cpuSeconds(_ usage: rusage) -> Double {
        Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
}
