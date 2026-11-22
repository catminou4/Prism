import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

struct SportsHomeShelf: View {
    @Environment(AppModel.self) private var app
    @Environment(NavigationModel.self) private var navigation
    @Environment(SportsPresentation.self) private var sports: SportsPresentation?
    @Environment(\.playPrismItem) private var playItem

    var body: some View {
        VStack(spacing: 0) {
            if let sports {
                let fixtures = Self.homeFixtures(sports.fixtures, now: sports.now)
                if !fixtures.isEmpty {
                    // One union pass for the per-card status/source badges instead of
                    // ~16 independent glass effects across the shelf.
                    GlassEffectContainer(spacing: 8) {
                        Shelf(title: "Sport", items: fixtures, sizing: .wide, onHeaderTap: { navigation.select(.sports) }) { fixture in
                            SportsHomeCard(fixture: fixture, now: sports.now) {
                                let broadcasts = fixture.liveBroadcasts(at: .now)
                                if let broadcast = broadcasts.first, broadcasts.count == 1 {
                                    SportsPlayback(app: app, play: playItem)(broadcast)
                                } else {
                                    sports.destination = SportsDestination(fixture, now: .now)
                                    navigation.select(.sports)
                                }
                            }
                        }
                    }
                }
            }
        }
        .modifier(SportsUpdates())
    }

    static func homeFixtures(_ fixtures: [SportsFixture], now: Date) -> [SportsFixture] {
        let window = SportsPresentation.scheduleWindow(from: Calendar.current.startOfDay(for: now))
        let officialLive = fixtures.lazy.filter { $0.event?.status == .live }
        let officialUpcoming = fixtures.lazy.filter { $0.event?.status == .scheduled && now < $0.startsAt && $0.startsAt < window.end }
        let guide = fixtures.lazy.filter { $0.event == nil && !$0.isCompanionProgram }
        let named = guide.filter(\.isNamedBroadcast)
        let guideLive = named.filter { $0.isLive(at: now) }
        let guideUpcoming = named.filter { now < $0.startsAt && $0.startsAt < window.end }
        let ranked = Array(officialLive.prefix(8)) + Array(officialUpcoming.prefix(8))
            + Array(guideLive.prefix(8)) + Array(guideUpcoming.prefix(8))
        if !ranked.isEmpty { return deduplicated(ranked, limit: 8) }
        let standby = guide.filter { !$0.isNamedBroadcast && ($0.isLive(at: now) || now < $0.startsAt && $0.startsAt < window.end) }
        return deduplicated(Array(standby.prefix(20)), limit: 3)
    }

    private static func deduplicated(_ fixtures: [SportsFixture], limit: Int) -> [SportsFixture] {
        var seen: Set<String> = []
        var distinct: [SportsFixture] = []
        for fixture in fixtures where seen.insert(TitleNormalizer.key(fixture.title)).inserted {
            distinct.append(fixture)
            if distinct.count == limit { break }
        }
        return distinct
    }
}

private struct SportsHomeCard: View {
    @Environment(\.prismCardWidth) private var width
    let fixture: SportsFixture
    let now: Date
    let action: () -> Void

    var body: some View {
        let broadcasts = fixture.liveBroadcasts(at: now)
        let cardWidth = width ?? 250
        let size = CGSize(width: cardWidth, height: (cardWidth / PrismMetrics.wideAspectRatio).rounded())
        let channel = broadcasts.first?.channel.name ?? fixture.broadcasts.first?.channel.name
        Button(action: action) {
            SportsArtwork(fixture: fixture, size: size)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.26), location: 0),
                            .init(color: .clear, location: 0.28),
                            .init(color: .clear, location: 0.43),
                            .init(color: .black.opacity(0.55), location: 0.58),
                            .init(color: .black.opacity(0.82), location: 0.78),
                            .init(color: .black.opacity(0.94), location: 1),
                        ], startPoint: .top, endPoint: .bottom
                    )
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        if fixture.isLive(at: now) {
                            SportsStatus(fixture: fixture, now: now, onArtwork: true)
                        } else {
                            Text(SportsTypography.dayAndHour(fixture.startsAt, relativeTo: now))
                                .font(.caption.weight(.medium).monospacedDigit())
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .prismGlass(.dark, in: .capsule)
                    .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    if !broadcasts.isEmpty {
                        Image(systemName: broadcasts.count == 1 ? "play.fill" : "ellipsis")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 24, height: 24)
                            .prismGlass(.dark, in: .circle)
                            .padding(10)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(alignment: .bottom, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fixture.title)
                                .font(.headline)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .shadow(color: .black.opacity(0.58), radius: 3, y: 1)
                            Text(channel ?? fixture.competition)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.76))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let score {
                            Text(score)
                                .font(.system(.caption, design: .monospaced, weight: .semibold))
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(.black.opacity(0.42), in: .capsule)
                        }
                    }
                    .padding(11)
                }
                .foregroundStyle(.white)
                .clipShape(.rect(cornerRadius: PrismMetrics.wideRadius))
        }
        .buttonStyle(CardButtonStyle(hoverScale: 1.025))
        .accessibilityLabel(fixture.title)
        .accessibilityValue([
            SportsTypography.dayAndHour(fixture.startsAt, relativeTo: now), fixture.state(at: now), score, channel,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(broadcasts.count == 1 ? "Regarder la diffusion" : "Ouvrir la rubrique Sport")
    }

    private var score: String? {
        guard fixture.showsScore, let home = fixture.event?.home.score, let away = fixture.event?.away.score else { return nil }
        return "\(home) – \(away)"
    }
}

struct SportsTeamLine: View {
    let team: SportsTeam
    let showsScore: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let url = team.logoURL {
                RemoteImage(url: url, size: CGSize(width: 17, height: 17), contentMode: .fit,
                            placeholderSeed: team.id, showsPlaceholder: false)
                    .accessibilityHidden(true)
            }
            Text(team.name)
                .font(.headline)
                .lineLimit(1)
            if showsScore, let score = team.score {
                Spacer(minLength: 8)
                Text(score.formatted())
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel("\(score) points")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct SportsStatus: View {
    let fixture: SportsFixture
    let now: Date
    var onArtwork = false

    var body: some View {
        HStack(spacing: 5) {
            if fixture.isLive(at: now) {
                Circle().fill(PrismColors.live).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            Text(fixture.state(at: now))
                .font(.caption.weight(.medium))
                .foregroundStyle(onArtwork ? .white : .secondary)
                .lineLimit(1)
        }
    }
}

enum SportsTypography {
    private static let french = Locale(identifier: "fr-FR")

    static func hour(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(french))
    }

    static func dayAndHour(_ date: Date, relativeTo now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) { return hour(date) }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).locale(french)).capitalized) \(hour(date))"
    }

    static func longDay(_ date: Date) -> String {
        let formatted = date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(french))
        return formatted.prefix(1).uppercased() + formatted.dropFirst()
    }
}
