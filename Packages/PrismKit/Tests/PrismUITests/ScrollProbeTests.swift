import AppKit
import Darwin
import PrismCore
import PrismData
@testable import PrismDesign
import QuartzCore
import SwiftUI
import Testing
@testable import PrismUI

/// Deeper bisection of the `browseShelves` materialization spike. Run in Release with
/// PRISM_SCROLL_PERF=1. Same offscreen-window harness as `ScrollPerformanceTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_SCROLL_PERF"] == "1"))
struct ScrollProbeTests {
    /// Times each phase of a scroll step separately: NSScrollView scroll, SwiftUI layout,
    /// layer display and the CoreAnimation commit.
    @Test func phaseBreakdown() async throws {
        _ = NSApplication.shared
        let titles = (0..<360).map { index in
            MediaTitle(id: TitleID(rawValue: "movie:\(index)"), kind: .movie,
                       title: "Film \(index)", year: 2000 + index % 25, variants: [])
        }
        let model = AppModel(directories: .temporary("prism-probe-phase"), credentials: InMemoryCredentialStore(),
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
        .environment(\.prismIsScrollingContent, true)
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
        let steps = 240
        var scrollSamples: [Double] = []
        var layoutSamples: [Double] = []
        var displaySamples: [Double] = []
        var flushSamples: [Double] = []
        var totalSamples: [Double] = []
        for step in 1...steps {
            try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
            let offset = min(step, steps - step)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 24))
            var t = clock.now
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            scrollSamples.append(milliseconds(t.duration(to: clock.now)))
            t = clock.now
            host.layoutSubtreeIfNeeded()
            layoutSamples.append(milliseconds(t.duration(to: clock.now)))
            t = clock.now
            host.displayIfNeeded()
            displaySamples.append(milliseconds(t.duration(to: clock.now)))
            t = clock.now
            CATransaction.flush()
            flushSamples.append(milliseconds(t.duration(to: clock.now)))
            totalSamples.append(scrollSamples.last! + layoutSamples.last! + displaySamples.last! + flushSamples.last!)
        }
        for (name, samples) in [("scroll", scrollSamples), ("layout", layoutSamples), ("display", displaySamples), ("flush", flushSamples), ("total", totalSamples)] {
            let sorted = samples.sorted()
            print("[probe-phase] \(name): p50 \(format(sorted[119])) ms, p95 \(format(sorted[227])) ms, "
                + "max \(format(sorted[239])) ms, \(samples.count { $0 > 1_000.0 / 120 })/240 over 8.33 ms")
        }
        print("[probe-phase] slow totals: \(totalSamples.enumerated().filter { $0.element > 1_000.0 / 120 }.map { "\($0.offset + 1):\(format($0.element))" }.joined(separator: ", "))")
        print("[probe-phase] slow layout: \(layoutSamples.enumerated().filter { $0.element > 3 }.map { "\($0.offset + 1):\(format($0.element))" }.joined(separator: ", "))")
        print("[probe-phase] slow display: \(displaySamples.enumerated().filter { $0.element > 3 }.map { "\($0.offset + 1):\(format($0.element))" }.joined(separator: ", "))")
    }

    /// Card-subtree bisection: same shelf scroll, different card bodies.
    @Test func cardSubtrees() async throws {
        _ = NSApplication.shared
        let titles = (0..<360).map { index in
            MediaTitle(id: TitleID(rawValue: "movie:\(index)"), kind: .movie,
                       title: "Film \(index)", year: 2000 + index % 25, variants: [])
        }
        let model = AppModel(directories: .temporary("prism-probe-cards"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)

        struct ShelfItem: Identifiable { let id: Int }

        func run<Card: View>(_ name: String, shelves: Int = 20, perShelf: Int = 18,
                             @ViewBuilder card: @escaping (Int) -> Card) async throws {
            let host = NSHostingView(rootView: ScrollView {
                LazyVStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
                    ForEach(0..<shelves) { shelf in
                        Shelf(title: "Sélection \(shelf)",
                              items: (0..<perShelf).map { ShelfItem(id: shelf * perShelf + $0) },
                              posterArtwork: nil) { item in
                            card(item.id)
                        }
                    }
                }
            }
            .environment(\.prismIsScrollingContent, true)
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
            let steps = 240
            var samples: [Double] = []
            samples.reserveCapacity(steps)
            for step in 1...steps {
                try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
                let offset = min(step, steps - step)
                let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 24))
                let sampleStart = clock.now
                clip.scroll(to: destination)
                scroll.reflectScrolledClipView(clip)
                layout(host)
                samples.append(milliseconds(sampleStart.duration(to: clock.now)))
            }
            let sorted = samples.sorted()
            print("[probe-card] \(name): p50 \(format(sorted[119])) ms, p95 \(format(sorted[227])) ms, "
                + "max \(format(sorted[239])) ms, \(samples.count { $0 > 1_000.0 / 120 })/240 over 8.33 ms")
        }

        // Sanity: the real card path (BrowsePoster inside Shelf, like TitleShelf).
        try await run("browsePoster") { index in
            BrowsePoster(item: titles[index])
        }

        // PosterCard variants — isolate chrome layers.
        try await run("posterPlain") { index in
            PosterCard(imageURL: nil, seed: "Film \(index)", title: "Film \(index)")
        }
        try await run("posterAction") { index in
            PosterCard(imageURL: nil, seed: "Film \(index)", title: "Film \(index)", action: {})
        }
        try await run("posterMenu") { index in
            PosterCard(imageURL: nil, seed: "Film \(index)", title: "Film \(index)", action: {}) {
                Button("Lire") {}
            }
        }
        try await run("posterTitle") { index in
            PosterCard(imageURL: nil, seed: "Film \(index)", title: "Film \(index)",
                       subtitle: "20\(index % 25)", showsTitle: true, action: {}) {
                Button("Lire") {}
            }
        }

        // Deeper: artwork subtree only, no CardContainer.
        try await run("remoteImage") { index in
            RemoteImage(url: nil, size: CGSize(width: 138, height: 207),
                        placeholderSeed: "Film \(index)", placeholderTitle: "Film \(index)")
        }
        try await run("placeholderGradients") { index in
            PlaceholderArtwork(seed: "Film \(index)")
                .frame(width: 138, height: 207)
                .clipped()
        }
        try await run("placeholderText") { index in
            PlaceholderArtwork(seed: "Film \(index)", title: "Film \(index)")
                .frame(width: 138, height: 207)
                .clipped()
        }
        try await run("surfaceRemote") { index in
            ArtworkSurface(radius: PrismMetrics.posterRadius) {
                RemoteImage(url: nil, size: CGSize(width: 138, height: 207),
                            placeholderSeed: "Film \(index)", placeholderTitle: "Film \(index)")
            }
            .frame(width: 138, height: 207)
        }

        // Render-cost floor: flat fill, same footprint, no gradients/text/clip.
        try await run("flatColor") { index in
            Color(white: 0.2)
                .frame(width: 138, height: 207)
                .clipShape(.rect(cornerRadius: 12))
        }

        // Caption-only cost.
        try await run("captions") { index in
            VStack(alignment: .leading, spacing: 8) {
                Color.clear.frame(width: 138, height: 207)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Film \(index)").font(PrismFont.cardTitle).foregroundStyle(.primary)
                    Text("20\(index % 25)").font(PrismFont.cardMeta).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: 138, alignment: .leading)
            }
        }

        // Shelf-machinery bisection: `ProbeShelf` replicates Shelf's row with a feature
        // bitmask, isolating what header/scroll-target/observer/modifier layers cost.
        let cardWidth = PrismMetrics.columnWidth(
            available: size.width - PrismMetrics.contentMargin * 2,
            minWidth: PrismMetrics.posterMinWidth,
            spacing: PrismMetrics.cardSpacing
        )
        func flat(_ index: Int) -> some View {
            Color(white: 0.2)
                .frame(width: 138, height: 207)
                .clipShape(.rect(cornerRadius: 12))
        }
        try await runShelfProbe("shelf=f0 bare", features: 0, cardWidth: cardWidth) { flat($0) }
        try await runShelfProbe("shelf=f1 paging", features: 1, cardWidth: cardWidth) { flat($0) }
        try await runShelfProbe("shelf=f2 observers", features: 2, cardWidth: cardWidth) { flat($0) }
        try await runShelfProbe("shelf=f4 header", features: 4, cardWidth: cardWidth) { flat($0) }
        try await runShelfProbe("shelf=f8 misc", features: 8, cardWidth: cardWidth) { flat($0) }
        try await runShelfProbe("shelf=f15 all", features: 15, cardWidth: cardWidth) { flat($0) }
        try await runShelfProbe("shelf=f15 poster", features: 15, cardWidth: cardWidth) { index in
            PosterCard(imageURL: nil, seed: "Film \(index)", title: "Film \(index)",
                       subtitle: "20\(index % 25)", showsTitle: true, action: {}) {
                Button("Lire") {}
            }
        }
        try await runShelfProbe("shelf=f0 poster", features: 0, cardWidth: cardWidth) { index in
            PosterCard(imageURL: nil, seed: "Film \(index)", title: "Film \(index)",
                       subtitle: "20\(index % 25)", showsTitle: true, action: {}) {
                Button("Lire") {}
            }
        }
        // Which feature group multiplies card cost? Poster under each group alone.
        for bit in [1, 2, 4, 8] {
            try await runShelfProbe("shelf=f\(bit) poster", features: bit, cardWidth: cardWidth) { index in
                PosterCard(imageURL: nil, seed: "Film \(index)", title: "Film \(index)",
                           subtitle: "20\(index % 25)", showsTitle: true, action: {}) {
                    Button("Lire") {}
                }
            }
        }
    }

    /// Scroll harness driving `ProbeShelf` (a `Shelf` replica with toggleable feature
    /// groups) instead of the real `Shelf`.
    private func runShelfProbe<Card: View>(_ name: String, features: Int, cardWidth: CGFloat,
                                           shelves: Int = 20, perShelf: Int = 18,
                                           @ViewBuilder card: @escaping (Int) -> Card) async throws {
        _ = NSApplication.shared
        let model = AppModel(directories: .temporary("prism-probe-shelf"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: ScrollView {
            LazyVStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
                ForEach(0..<shelves) { shelf in
                    ProbeShelf(title: "Sélection \(shelf)", count: perShelf, features: features,
                               cardWidth: cardWidth) { card(shelf * perShelf + $0) }
                }
            }
        }
        .environment(\.prismIsScrollingContent, true)
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
        let steps = 240
        var samples: [Double] = []
        samples.reserveCapacity(steps)
        for step in 1...steps {
            try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
            let offset = min(step, steps - step)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 24))
            let sampleStart = clock.now
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            layout(host)
            samples.append(milliseconds(sampleStart.duration(to: clock.now)))
        }
        let sorted = samples.sorted()
        print("[probe-shelf] \(name): p50 \(format(sorted[119])) ms, p95 \(format(sorted[227])) ms, "
            + "max \(format(sorted[239])) ms, \(samples.count { $0 > 1_000.0 / 120 })/240 over 8.33 ms")
    }

    /// Same scroll harness as `cardSubtrees().run`, but rows are `ProbeRow` — a minimal
    /// horizontal ScrollView + LazyHStack without Shelf's header and scroll machinery.
    private func runBare<Card: View>(_ name: String, shelves: Int = 20, perShelf: Int = 18,
                                     @ViewBuilder card: @escaping (Int) -> Card) async throws {
        _ = NSApplication.shared
        let model = AppModel(directories: .temporary("prism-probe-bare"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)
        // Same column width Shelf computes for `.posters` sizing at this viewport.
        let cardWidth = PrismMetrics.columnWidth(
            available: size.width - PrismMetrics.contentMargin * 2,
            minWidth: PrismMetrics.posterMinWidth,
            spacing: PrismMetrics.cardSpacing
        )
        let host = NSHostingView(rootView: ScrollView {
            LazyVStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
                ForEach(0..<shelves) { shelf in
                    ProbeRow(count: perShelf) { card(shelf * perShelf + $0) }
                        .prismCardWidth(cardWidth)
                }
            }
        }
        .environment(\.prismIsScrollingContent, true)
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
        let steps = 240
        var samples: [Double] = []
        samples.reserveCapacity(steps)
        for step in 1...steps {
            try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
            let offset = min(step, steps - step)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 24))
            let sampleStart = clock.now
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            layout(host)
            samples.append(milliseconds(sampleStart.duration(to: clock.now)))
        }
        let sorted = samples.sorted()
        print("[probe-bare] \(name): p50 \(format(sorted[119])) ms, p95 \(format(sorted[227])) ms, "
            + "max \(format(sorted[239])) ms, \(samples.count { $0 > 1_000.0 / 120 })/240 over 8.33 ms")
    }

    /// Bisects `CardContainer`'s chrome: Button vs tap gesture vs nothing, and each modifier.
    /// Bitmask `chrome`: 1 = no Button (plain + onTapGesture), 2 = no context menu,
    /// 4 = no accessibility modifiers, 8 = no hover tracking, 16 = no prismCardLifted env.
    @Test func chromeBisect() async throws {
        _ = NSApplication.shared
        let model = AppModel(directories: .temporary("prism-probe-chrome"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)

        struct ShelfItem: Identifiable { let id: Int }

        @ViewBuilder
        func card(_ index: Int, chrome: Int) -> some View {
            ProbeCard(action: {}, menu: { Button("Lire") {} }, chrome: chrome) { _ in
                ArtworkSurface(radius: PrismMetrics.posterRadius) {
                    RemoteImage(url: nil, size: CGSize(width: 138, height: 207),
                                placeholderSeed: "Film \(index)", placeholderTitle: nil)
                }
                .frame(width: 138, height: 207)
            }
        }

        func run(_ name: String, chrome: Int) async throws {
            let host = NSHostingView(rootView: ScrollView {
                LazyVStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
                    ForEach(0..<20) { shelf in
                        Shelf(title: "Sélection \(shelf)",
                              items: (0..<18).map { ShelfItem(id: shelf * 18 + $0) },
                              posterArtwork: nil) { item in
                            card(item.id, chrome: chrome)
                        }
                    }
                }
            }
            .environment(\.prismIsScrollingContent, true)
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
            let steps = 240
            var samples: [Double] = []
            samples.reserveCapacity(steps)
            for step in 1...steps {
                try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
                let offset = min(step, steps - step)
                let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 24))
                let sampleStart = clock.now
                clip.scroll(to: destination)
                scroll.reflectScrolledClipView(clip)
                layout(host)
                samples.append(milliseconds(sampleStart.duration(to: clock.now)))
            }
            let sorted = samples.sorted()
            print("[probe-chrome] \(name): p50 \(format(sorted[119])) ms, p95 \(format(sorted[227])) ms, "
                + "max \(format(sorted[239])) ms, \(samples.count { $0 > 1_000.0 / 120 })/240 over 8.33 ms")
        }

        try await run("chrome=0 (all)", chrome: 0)
        try await run("chrome=1 (tap not button)", chrome: 1)
        try await run("chrome=2 (no ctxmenu)", chrome: 2)
        try await run("chrome=4 (no a11y)", chrome: 4)
        try await run("chrome=8 (no hover)", chrome: 8)
        try await run("chrome=16 (no lift env)", chrome: 16)
        try await run("chrome=31 (bare)", chrome: 31)
    }

    /// Grid-layout bisection with process-CPU samples. Every configuration is measured
    /// several times interleaved; the reported run is the one with the lowest p95 wall
    /// (noise can only inflate these synchronous samples). `totalCPU` also charges work
    /// performed by helper/render threads while the timed scroll is underway, which the
    /// per-step main-thread samples cannot see.
    @Test func gridRowsAndEntrance() async throws {
        var results: [ProbeGridMode: [ProbeRunResult]] = [:]
        for repetition in 0..<4 {
            let forward = repetition.isMultiple(of: 2)
            let modes = forward ? ProbeGridMode.allCases : ProbeGridMode.allCases.reversed()
            for mode in modes {
                results[mode, default: []].append(try await runGridProbe(mode))
            }
        }
        for mode in ProbeGridMode.allCases {
            let values = results[mode] ?? []
            guard let bestWall = values.min(by: { $0.p95Wall < $1.p95Wall }),
                  let bestCPU = values.min(by: { $0.totalCPU < $1.totalCPU }) else { continue }
            print("[probe-grid] \(mode.rawValue) best-wall: wall p50 \(format(bestWall.p50Wall)) ms, "
                + "p95 \(format(bestWall.p95Wall)) ms, max \(format(bestWall.maxWall)) ms, "
                + "\(bestWall.overBudget)/\(bestWall.steps) over 8.33 ms; step CPU p50 \(format(bestWall.p50CPU)) ms, "
                + "p95 \(format(bestWall.p95CPU)) ms, max \(format(bestWall.maxCPU)) ms; "
                + "total CPU \(format(bestWall.totalCPU)) ms over \(format(bestWall.wallSeconds)) s, "
                + "tail CPU \(format(bestWall.tailCPU)) ms")
            print("[probe-grid] \(mode.rawValue) best-cpu: wall p50 \(format(bestCPU.p50Wall)) ms, "
                + "p95 \(format(bestCPU.p95Wall)) ms, max \(format(bestCPU.maxWall)) ms; "
                + "total CPU \(format(bestCPU.totalCPU)) ms over \(format(bestCPU.wallSeconds)) s, "
                + "tail CPU \(format(bestCPU.tailCPU)) ms")
        }
    }

    /// Focused duration scaling check for the row entrance animation.
    @Test func gridEntranceDurations() async throws {
        let modes: [ProbeGridMode] = [.rowsEntrance, .rowsEntrance35, .rowsEntrance20, .rowsNoEntrance]
        var results: [ProbeGridMode: [ProbeRunResult]] = [:]
        for _ in 0..<4 {
            for mode in modes {
                results[mode, default: []].append(try await runGridProbe(mode))
            }
        }
        for mode in modes {
            guard let best = results[mode]?.min(by: { $0.totalCPU < $1.totalCPU }) else { continue }
            print("[probe-grid-duration] \(mode.rawValue): wall p50 \(format(best.p50Wall)) ms, p95 \(format(best.p95Wall)) ms, "
                + "max \(format(best.maxWall)) ms; total CPU \(format(best.totalCPU)) ms, tail CPU \(format(best.tailCPU)) ms")
        }
    }

    private func runGridProbe(_ mode: ProbeGridMode) async throws -> ProbeRunResult {
        _ = NSApplication.shared
        let titles = (0..<20_000).map { index in
            MediaTitle(id: TitleID(rawValue: "movie:\(index)"), kind: .movie,
                       title: "Film \(index)", year: 2000 + index % 25, variants: [])
        }
        let model = AppModel(directories: .temporary("prism-probe-grid"), credentials: InMemoryCredentialStore(),
                             library: .inMemory(), isEphemeral: true)
        let navigation = NavigationModel()
        let size = CGSize(width: 1_170, height: 870)
        let frame = CGRect(origin: .zero, size: size)
        let host = NSHostingView(rootView: ScrollView {
            ProbeGridContent(mode: mode, items: titles, availableWidth: size.width)
        }
        .environment(\.prismIsScrollingContent, true)
        .frame(width: size.width, height: size.height)
        .environment(model)
        .environment(navigation))
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
        let steps = 180
        var wallSamples: [Double] = []
        var cpuSamples: [Double] = []
        wallSamples.reserveCapacity(steps)
        cpuSamples.reserveCapacity(steps)
        let start = clock.now
        let scrollCPUStart = processCPUMilliseconds()
        for step in 1...steps {
            try await clock.sleep(until: start.advanced(by: .nanoseconds(8_333_333) * step))
            let offset = min(step, steps - step)
            let destination = CGPoint(x: origin.x, y: origin.y + direction * CGFloat(offset * 48))
            let sampleStart = clock.now
            let cpuStart = processCPUMilliseconds()
            clip.scroll(to: destination)
            scroll.reflectScrolledClipView(clip)
            layout(host)
            wallSamples.append(milliseconds(sampleStart.duration(to: clock.now)))
            cpuSamples.append(processCPUMilliseconds() - cpuStart)
        }
        let wallSeconds = milliseconds(start.duration(to: clock.now)) / 1_000
        let totalCPU = processCPUMilliseconds() - scrollCPUStart
        let tailCPUStart = processCPUMilliseconds()
        try await Task.sleep(for: .milliseconds(500))
        layout(host)
        let tailCPU = processCPUMilliseconds() - tailCPUStart
        return ProbeRunResult(steps: steps, wall: wallSamples, cpu: cpuSamples,
                              totalCPU: totalCPU, tailCPU: tailCPU, wallSeconds: wallSeconds)
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
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

    private func processCPUMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        return seconds * 1_000
    }
}

private enum ProbeGridMode: String, CaseIterable {
    /// `TitleGrid` exactly as the collection pages use it today.
    case gridCurrent = "grid/current"
    /// Same `LazyVGrid`, with the per-card scroll transition removed.
    case gridNoEntrance = "grid/no-entrance"
    /// Rows materialized as units; one shared scroll transition per row. Cards in a row
    /// have identical vertical positions, so their entrance phase is identical too.
    case rowsEntrance = "rows/entrance"
    /// Row layout floor with no scroll-transition tracking at all.
    case rowsNoEntrance = "rows/no-entrance"
    /// Row transition driven directly by scroll position rather than a 0.5 s trailing animation.
    case rowsDirectEntrance = "rows/direct-entrance"
    /// Animated row transition applied to a compositing group.
    case rowsEntranceComposited = "rows/entrance-composited"
    /// Direct row transition applied to a compositing group.
    case rowsDirectComposited = "rows/direct-composited"
    /// Discrete entrance animation triggered once by visibility instead of `scrollTransition`.
    case rowsVisibilityEntrance = "rows/visibility-entrance"
    /// Same scroll transition with a shorter discrete animation.
    case rowsEntrance35 = "rows/entrance-0.35"
    case rowsEntrance20 = "rows/entrance-0.20"
}

private struct ProbeRunResult {
    let steps: Int
    let p50Wall: Double
    let p95Wall: Double
    let maxWall: Double
    let overBudget: Int
    let p50CPU: Double
    let p95CPU: Double
    let maxCPU: Double
    let totalCPU: Double
    let tailCPU: Double
    let wallSeconds: Double

    init(steps: Int, wall: [Double], cpu: [Double], totalCPU: Double, tailCPU: Double, wallSeconds: Double) {
        func percentile(_ samples: [Double], _ fraction: Double) -> Double {
            let sorted = samples.sorted()
            return sorted[min(samples.count - 1, max(0, Int((Double(samples.count) * fraction).rounded(.up)) - 1))]
        }
        self.steps = steps
        p50Wall = percentile(wall, 0.50)
        p95Wall = percentile(wall, 0.95)
        maxWall = wall.max() ?? 0
        overBudget = wall.count { $0 > 1_000.0 / 120 }
        p50CPU = percentile(cpu, 0.50)
        p95CPU = percentile(cpu, 0.95)
        maxCPU = cpu.max() ?? 0
        self.totalCPU = totalCPU
        self.tailCPU = tailCPU
        self.wallSeconds = wallSeconds
    }
}

private struct ProbeGridContent: View {
    let mode: ProbeGridMode
    let items: [MediaTitle]
    let availableWidth: CGFloat

    var body: some View {
        switch mode {
        case .gridCurrent:
            TitleGrid(items: items, availableWidth: availableWidth)
        case .gridNoEntrance:
            ProbeLazyGrid(items: items, availableWidth: availableWidth, entrance: false)
        case .rowsEntrance:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .animated)
        case .rowsNoEntrance:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .none)
        case .rowsDirectEntrance:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .direct)
        case .rowsEntranceComposited:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .animatedComposited)
        case .rowsDirectComposited:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .directComposited)
        case .rowsVisibilityEntrance:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .visibility)
        case .rowsEntrance35:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .animated35)
        case .rowsEntrance20:
            ProbeRowGrid(items: items, availableWidth: availableWidth, entrance: .animated20)
        }
    }
}

/// Exact `TitleGrid` geometry, with entrance transitions switchable for measurement.
private struct ProbeLazyGrid: View {
    let items: [MediaTitle]
    let availableWidth: CGFloat
    let entrance: Bool

    var body: some View {
        let spacing: CGFloat = 20
        let contentWidth = max(140, availableWidth - 2 * PrismMetrics.contentMargin)
        let count = max(1, Int((contentWidth + spacing) / (145 + spacing)))
        let width = (contentWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
        let columns = Array(repeating: GridItem(.fixed(width), spacing: spacing), count: count)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 28) {
            ForEach(items) { item in
                if entrance {
                    BrowsePoster(item: item, width: width)
                        .rowEntrance()
                } else {
                    BrowsePoster(item: item, width: width)
                }
            }
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
    }
}

/// The same fixed-column grid expressed as independently materialized rows. Because every
/// card in one row has the same vertical geometry, a single row-level scroll transition
/// produces the same entrance phase as six identical card-level transitions.
private enum ProbeEntranceStyle {
    case none, animated, direct, animatedComposited, directComposited, visibility, animated35, animated20
}

private struct ProbeRowGrid: View {
    let items: [MediaTitle]
    let availableWidth: CGFloat
    let entrance: ProbeEntranceStyle

    var body: some View {
        let spacing: CGFloat = 20
        let contentWidth = max(140, availableWidth - 2 * PrismMetrics.contentMargin)
        let count = max(1, Int((contentWidth + spacing) / (145 + spacing)))
        let width = (contentWidth - CGFloat(count - 1) * spacing) / CGFloat(count)
        let rowCount = (items.count + count - 1) / count
        LazyVStack(alignment: .leading, spacing: PrismMetrics.gridRowSpacing) {
            ForEach(0..<rowCount, id: \.self) { row in
                ProbeGridRow(items: items, row: row, columns: count, width: width,
                             contentWidth: contentWidth, spacing: spacing, entrance: entrance)
                    .padding(.horizontal, PrismMetrics.contentMargin)
            }
        }
    }
}

private struct ProbeGridRow: View {
    let items: [MediaTitle]
    let row: Int
    let columns: Int
    let width: CGFloat
    let contentWidth: CGFloat
    let spacing: CGFloat
    let entrance: ProbeEntranceStyle

    var body: some View {
        let start = row * columns
        let end = min(items.count, start + columns)
        let content = HStack(alignment: .top, spacing: spacing) {
            ForEach(start..<end, id: \.self) { index in
                BrowsePoster(item: items[index], width: width)
            }
        }
        .frame(width: contentWidth, alignment: .leading)

        switch entrance {
        case .none:
            content
        case .animated:
            content.rowEntrance()
        case .direct:
            content.probeDirectRowEntrance()
        case .animatedComposited:
            content.compositingGroup().rowEntrance()
        case .directComposited:
            content.compositingGroup().probeDirectRowEntrance()
        case .visibility:
            content.probeVisibilityRowEntrance()
        case .animated35:
            content.probeAnimatedRowEntrance(duration: 0.35)
        case .animated20:
            content.probeAnimatedRowEntrance(duration: 0.20)
        }
    }
}

private struct ProbeDirectRowEntrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotRendering) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            let moves = !reduceMotion
            content.scrollTransition(.interactive.threshold(.visible(0.08)), axis: .vertical) { view, phase in
                view
                    .opacity(phase.value > 0 ? 0 : 1)
                    .scaleEffect(phase.value > 0 && moves ? 0.97 : 1, anchor: .top)
                    .offset(y: phase.value > 0 && moves ? 28 : 0)
            }
        }
    }
}

private struct ProbeAnimatedRowEntrance: ViewModifier {
    let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotRendering) private var isSnapshot

    func body(content: Content) -> some View {
        if isSnapshot {
            content
        } else {
            let moves = !reduceMotion
            content.scrollTransition(.animated(.smooth(duration: duration)).threshold(.visible(0.08)), axis: .vertical) { view, phase in
                view
                    .opacity(phase.value > 0 ? 0 : 1)
                    .scaleEffect(phase.value > 0 && moves ? 0.97 : 1, anchor: .top)
                    .offset(y: phase.value > 0 && moves ? 28 : 0)
            }
        }
    }
}

private struct ProbeVisibilityRowEntrance: ViewModifier {
    @State private var entered = false
    @State private var initialized = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotRendering) private var isSnapshot

    func body(content: Content) -> some View {
        let shown = entered || isSnapshot
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown || reduceMotion ? 1 : 0.97, anchor: .top)
            .offset(y: shown || reduceMotion ? 0 : 28)
            .animation(PrismMotion.entrance, value: entered)
            .onScrollVisibilityChange(threshold: 0.08) { visible in
                if visible && !entered {
                    if initialized {
                        entered = true
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { entered = true }
                    }
                }
                initialized = true
            }
    }
}

private extension View {
    func probeDirectRowEntrance() -> some View {
        modifier(ProbeDirectRowEntrance())
    }

    func probeVisibilityRowEntrance() -> some View {
        modifier(ProbeVisibilityRowEntrance())
    }

    func probeAnimatedRowEntrance(duration: Double) -> some View {
        modifier(ProbeAnimatedRowEntrance(duration: duration))
    }
}

/// `Shelf` replica with toggleable feature groups, used by `runShelfProbe` to attribute
/// the per-shelf materialization cost. Bitmask: 1 = paging (scrollTargetLayout +
/// viewAligned + scrollPosition + defaultScrollAnchor), 2 = observers (geometry, phase,
/// visibility, hover, scroll action, state resets), 4 = header, 8 = misc chrome
/// (env writes, animation, chevron overlays, lift-inset paddings).
private struct ProbeShelf<Card: View>: View {
    let title: String
    let count: Int
    let features: Int
    let cardWidth: CGFloat
    let card: (Int) -> Card

    @State private var leadingItem: Int?
    @State private var scrollAvailability = ProbeAvailability()
    @State private var hovering = false
    @State private var rowScrolling = false
    @Environment(\.prismIsScrollingContent) private var isScrollingContent
    @Environment(\.prismSnapshotHover) private var forcedHover
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHovered: Bool { (hovering || forcedHover) && !isScrollingContent }

    var body: some View {
        if features & 4 != 0 {
            VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
                ShelfHeader(title)
                    .padding(.horizontal, PrismMetrics.contentMargin)
                    .zIndex(1)
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: PrismMetrics.cardSpacing) {
                ForEach(0..<count) { card($0) }
            }
            .modifier(ProbeTargetLayout(enabled: features & 1 != 0))
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .contentMargins(.horizontal, PrismMetrics.contentMargin, for: .scrollContent)
        .modifier(ProbePaging(enabled: features & 1 != 0, leadingItem: $leadingItem))
        .modifier(ProbeEnvironments(enabled: features & 8 != 0,
                                    isScrolling: isScrollingContent || rowScrolling,
                                    cardWidth: cardWidth))
        .modifier(ProbeObservers(enabled: features & 2 != 0,
                                 isScrollingContent: isScrollingContent,
                                 setRowScrolling: { rowScrolling = $0 },
                                 setHovering: { hovering = $0 }))
        .modifier(ProbeRowChrome(enabled: features & 8 != 0,
                                 isHovered: isHovered,
                                 canScroll: scrollAvailability,
                                 reduceMotion: reduceMotion))
    }
}

private struct ProbeAvailability: Equatable {
    var backward = false
    var forward = false
}

private struct ProbeTargetLayout: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.scrollTargetLayout() } else { content }
    }
}

private struct ProbePaging: ViewModifier {
    let enabled: Bool
    @Binding var leadingItem: Int?
    func body(content: Content) -> some View {
        if enabled {
            content
                .defaultScrollAnchor(.leading, for: .initialOffset)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
                .scrollPosition(id: $leadingItem, anchor: .leading)
        } else {
            content
        }
    }
}

private struct ProbeEnvironments: ViewModifier {
    let enabled: Bool
    let isScrolling: Bool
    let cardWidth: CGFloat
    func body(content: Content) -> some View {
        if enabled {
            content
                .environment(\.prismIsScrollingContent, isScrolling)
                .prismCardWidth(cardWidth)
        } else {
            content
        }
    }
}

private struct ProbeObservers: ViewModifier {
    let enabled: Bool
    let isScrollingContent: Bool
    let setRowScrolling: (Bool) -> Void
    let setHovering: (Bool) -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .onScrollPhaseChange { _, phase in
                    setRowScrolling(phase.isScrolling)
                }
                .onScrollGeometryChange(for: Bool.self) { _ in false } action: { _, _ in }
                .onScrollVisibilityChange(threshold: 0.15) { _ in }
                .onHover { inside in
                    guard !isScrollingContent else { return }
                    setHovering(inside)
                }
                .onChange(of: isScrollingContent) { _, scrolling in
                    if !scrolling { setHovering(false) }
                }
                .accessibilityScrollAction { _ in }
        } else {
            content
        }
    }
}

private struct ProbeRowChrome: ViewModifier {
    let enabled: Bool
    let isHovered: Bool
    let canScroll: ProbeAvailability
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .padding(.top, -24)
                .padding(.bottom, -40)
                .overlay(alignment: .leading) { chevron(.leading, isHovered: isHovered, canScroll: canScroll, reduceMotion: reduceMotion) }
                .overlay(alignment: .trailing) { chevron(.trailing, isHovered: isHovered, canScroll: canScroll, reduceMotion: reduceMotion) }
                .animation(PrismMotion.quickFade, value: canScroll)
        } else {
            content
        }
    }

    @ViewBuilder private func chevron(_ edge: HorizontalEdge, isHovered: Bool,
                                      canScroll: ProbeAvailability, reduceMotion: Bool) -> some View {
        let can = edge == .leading ? canScroll.backward : canScroll.forward
        if isHovered && can {
            GlassCircleButton(systemName: edge == .leading ? "chevron.left" : "chevron.right",
                              size: PrismMetrics.shelfChevronSize,
                              accessibilityLabel: edge == .leading ? "Précédent" : "Suivant") {}
                .padding(.horizontal, (PrismMetrics.contentMargin - PrismMetrics.shelfChevronSize) / 2)
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

/// Minimal horizontal row used by `runBare`: same footprint as `Shelf`'s row
/// (spacing, lift insets, margins) but none of its header or scroll machinery.
private struct ProbeRow<Card: View>: View {
    let count: Int
    let card: (Int) -> Card

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: PrismMetrics.cardSpacing) {
                ForEach(0..<count) { card($0) }
            }
            // Room for the hover lift + shadow, mirroring Shelf.liftInset.
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.never)
        .contentMargins(.horizontal, PrismMetrics.contentMargin, for: .scrollContent)
    }
}

/// Test-only replica of `CardContainer` whose chrome layers can be switched off by bitmask.
/// Mirrors CardSupport.swift; used solely by `ScrollProbeTests.chromeBisect`.
private struct ProbeCard<Content: View, MenuContent: View>: View {
    let action: (() -> Void)?
    let menu: () -> MenuContent
    let chrome: Int
    let content: (_ isHovered: Bool) -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotHover) private var forcedHover
    @Environment(\.prismIsScrollingContent) private var isScrollingContent

    private var isHovered: Bool { (hovering || forcedHover) && !isScrollingContent }

    var body: some View {
        Group {
            if let action {
                if chrome & 1 != 0 {
                    // Probe: tap gesture instead of Button (no press state, no button chrome).
                    content(isHovered)
                        .contentShape(.rect)
                        .onTapGesture { action() }
                } else {
                    Button(action: action) { content(isHovered) }
                        .buttonStyle(.plain)
                }
            } else {
                content(isHovered)
                    .hoverLiftEffect(isHovered: isHovered, isPressed: false, scale: 1.04,
                                     pressedScale: 0.97, shadow: false, reduceMotion: reduceMotion)
            }
        }
        .modifier(ChromeEnv(enabled: chrome & 16 == 0, isHovered: isHovered))
        .modifier(ChromeHover(enabled: chrome & 8 == 0, isScrollingContent: isScrollingContent) { hovering = $0 })
        .modifier(ChromeMenu(enabled: chrome & 2 == 0, menu: menu))
        .modifier(ChromeA11y(enabled: chrome & 4 == 0, isButton: action != nil))
        .focusEffectDisabled()
    }
}

private struct ChromeEnv: ViewModifier {
    let enabled: Bool
    let isHovered: Bool
    func body(content: Content) -> some View {
        if enabled { content.environment(\.prismCardLifted, isHovered) } else { content }
    }
}

private struct ChromeHover: ViewModifier {
    let enabled: Bool
    let isScrollingContent: Bool
    let setHovering: (Bool) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content
                .onHover { inside in
                    guard !isScrollingContent else { return }
                    setHovering(inside)
                }
                .onChange(of: isScrollingContent) { _, scrolling in
                    if !scrolling { setHovering(false) }
                }
        } else {
            content
        }
    }
}

private struct ChromeMenu<MenuContent: View>: ViewModifier {
    let enabled: Bool
    let menu: () -> MenuContent
    func body(content: Content) -> some View {
        if enabled {
            content.modifier(OptionalContextMenu(menu: menu))
        } else {
            content
        }
    }
}

private struct ChromeA11y: ViewModifier {
    let enabled: Bool
    let isButton: Bool
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isButton ? .isButton : [])
        } else {
            content
        }
    }
}
