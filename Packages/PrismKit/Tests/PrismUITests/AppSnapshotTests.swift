import AppKit
import Foundation
import PrismCore
import PrismData
import PrismDesign
import QuartzCore
import SwiftUI
import Testing
@testable import PrismUI

/// Host app surfaces offscreen. Run with `PRISM_APP_SNAPSHOTS=1 swift test --filter AppSnapshotTests`.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PRISM_APP_SNAPSHOTS"] == "1"))
struct AppSnapshotTests {
    @Test func mainSurfaces() async throws {
        let app = await AppModel.preview()
        let movie = try #require(app.catalog.movies.first { $0.variants.count > 1 })
        let series = try #require(app.catalog.series.first {
            $0.variants.contains { variant in
                app.source(variant.sourceID)?.kind == .m3uURL && variant.series?.seasons?.isEmpty == false
            }
        })
        let navigation = NavigationModel()

        try await write(OnboardingView().environment(app), label: "onboarding", size: CGSize(width: 1320, height: 820), settle: .seconds(2))
        try await write(
            PrismRootView(playback: PrismPlaybackSession()).environment(app),
            label: "home", size: CGSize(width: 1440, height: 900), scheme: .light
        )
        try await write(
            PrismRootView(playback: PrismPlaybackSession()).environment(app),
            label: "home-dark", size: CGSize(width: 1440, height: 900)
        )
        try await write(
            BrowseScreen(kind: nil).environment(app).environment(navigation).environment(SportsPresentation()),
            label: "home-content", size: CGSize(width: 1210, height: 900)
        )
        try await write(
            TitleDetailView(titleID: movie.id).environment(app).environment(navigation),
            label: "film", size: CGSize(width: 1170, height: 870)
        )
        try await write(
            TitleDetailView(titleID: series.id).environment(app).environment(navigation),
            label: "serie", size: CGSize(width: 1170, height: 870)
        )
        let options = movie.variants.compactMap { variant -> TitlePlaybackOption? in
            guard let source = app.source(variant.sourceID) else { return nil }
            return TitlePlaybackOption(edition: TitleEdition(variant: variant, source: source))
        }
        try await write(
            TitlePlaybackSheet(
                title: movie,
                selection: TitlePlaybackSelection(options: options, otherEditions: [], episode: nil, preferred: nil),
                repository: app.detailRepository,
                resumePosition: { _ in nil }, onPlay: { _, _ in }
            ),
            label: "editions", size: CGSize(width: 540, height: 540)
        )
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .light ? "-light" : ""
            try await write(
                LiveScreen().environment(app).environment(navigation),
                label: "live\(suffix)", size: CGSize(width: 1170, height: 870), scheme: scheme
            )
            try await write(
                LiveGuide(
                    channels: app.catalog.channels, guide: app.guide, start: .constant(nil), isRefreshing: false,
                    onRefresh: {}, onPlay: { _, _ in }, onReplay: { _, _, _ in nil }, channelMenu: { _, _ in EmptyView() }
                ),
                label: "guide\(suffix)", size: CGSize(width: 1170, height: 870), scheme: scheme
            )
        }
        let sport = try sportsFixture(in: app)
        for scheme in [ColorScheme.light, .dark] {
            try await write(
                SportsScreen().environment(app).environment(sport).environment(\.isPageActive, false),
                label: scheme == .light ? "sport-light" : "sport-dark", size: CGSize(width: 1170, height: 870), scheme: scheme
            )
            try await write(
                SportsHomeShelf().environment(app).environment(navigation).environment(sport).environment(\.isPageActive, false),
                label: scheme == .light ? "sport-shelf-light" : "sport-shelf-dark", size: CGSize(width: 1170, height: 248), scheme: scheme
            )
        }
    }

    private func sportsFixture(in app: AppModel) throws -> SportsPresentation {
        let now = Calendar.current.startOfDay(for: .now).addingTimeInterval(13 * 3600)
        let channel = try #require(app.catalog.channels.first { $0.name.localizedCaseInsensitiveContains("beIN Sports") }
            ?? app.catalog.channels.first { !$0.variants.isEmpty })
        let artwork = ProcessInfo.processInfo.environment["PRISM_SPORTS_SAMPLE_ART"]
            .flatMap { FileManager.default.fileExists(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
        let football = EPGProgram(
            channelID: channel.epgID ?? channel.id, start: now.addingTimeInterval(-900), end: now.addingTimeInterval(3600),
            title: "Nice – Paris Saint-Germain", category: "Football"
        )
        let event = SportsEvent(
            id: "fixture:league1", league: .ligue1, startsAt: football.start, status: .live,
            home: SportsTeam(id: "nice", name: "Nice", abbreviation: "OGCN", score: 1),
            away: SportsTeam(id: "paris", name: "Paris Saint-Germain", abbreviation: "PSG", score: 2),
            displayClock: "36′", artworkURL: artwork
        )
        let basketball = EPGProgram(
            channelID: channel.epgID ?? channel.id, start: now.addingTimeInterval(5400), end: now.addingTimeInterval(10800),
            title: "Chicago Bulls – Boston Celtics", category: "Basketball"
        )
        let boxing = EPGProgram(
            channelID: channel.epgID ?? channel.id, start: now.addingTimeInterval(16200), end: now.addingTimeInterval(21600),
            title: "Dubois – Parker", category: "Boxe"
        )
        let magazine = EPGProgram(
            channelID: channel.epgID ?? channel.id, start: now.addingTimeInterval(7200), end: now.addingTimeInterval(10_800),
            title: "NBA Today", category: "Basketball"
        )
        return SportsPresentation(fixtures: [
            SportsFixture(event: event, broadcasts: [SportsBroadcast(channel: channel, program: football, sport: .football)]),
            SportsFixture(broadcast: SportsBroadcast(channel: channel, program: basketball, sport: .basketball)),
            SportsFixture(broadcast: SportsBroadcast(channel: channel, program: boxing, sport: .boxing)),
            SportsFixture(broadcast: SportsBroadcast(channel: channel, program: magazine, sport: .basketball)),
        ], now: now)
    }

    private func write(
        _ view: some View, label: String, size: CGSize, scheme: ColorScheme = .dark, settle: Duration = .milliseconds(700)
    ) async throws {
        _ = NSApplication.shared
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        let host = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .background(PrismColors.pageBackground)
                .environment(\.locale, Locale(identifier: "fr-FR"))
                .environment(\.colorScheme, scheme)
                .environment(\.prismSnapshotRendering, true)
                .preferredColorScheme(scheme)
        )
        let frame = CGRect(origin: .zero, size: size)
        host.frame = frame
        host.appearance = appearance
        host.wantsLayer = true
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }

        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        try await Task.sleep(for: settle)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: frame))
        appearance.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: frame, to: bitmap)
        }
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = ProcessInfo.processInfo.environment["PRISM_SNAPSHOT_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appending(path: "PrismSnapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "app-\(label).png")
        try data.write(to: file)
        print("Snapshot Prism \(file.path)")
    }
}
