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
    @Environment(\.isPageActive) private var isActive
    @State private var memo = HomeFixturesMemo()

    var body: some View {
        VStack(spacing: 0) {
            if let sports {
                // The presentation is shared with the Sports page: while Home is buried
                // its ticks must not re-evaluate this shelf, and even visible, the
                // selection is memoized — five filter passes + per-fixture normalization
                // don't belong in every unrelated body evaluation.
                let now = isActive ? sports.now : Date.now
                let fixtures = memo.value(for: sports.fixtures, now: now)
                if !fixtures.isEmpty {
                    // One union pass for the per-card status/source badges instead of
                    // ~16 independent glass effects across the shelf.
                    GlassEffectContainer(spacing: 8) {
                        Shelf(title: "Sport", items: fixtures, sizing: .columns(minWidth: 260), onHeaderTap: { navigation.select(.sports) }) { fixture in
                            SportsHomeCard(fixture: fixture, now: now) {
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

/// Cache of the last home-shelf selection, keyed by its exact inputs. `homeFixtures`
/// runs five filter passes plus a per-fixture `TitleNormalizer` normalization; the
/// array equality check that gates the memo is far cheaper, so unrelated body
/// re-evaluations (scroll, hover, library writes) reuse the previous selection.
/// Not observed: the memo never invalidates anything by itself.
private final class HomeFixturesMemo {
    private var fixtures: [SportsFixture]?
    private var now: Date?
    private var result: [SportsFixture] = []

    func value(for fixtures: [SportsFixture], now: Date) -> [SportsFixture] {
        if self.fixtures == fixtures, self.now == now { return result }
        let result = SportsHomeShelf.homeFixtures(fixtures, now: now)
        self.fixtures = fixtures
        self.now = now
        self.result = result
        return result
    }
}

private struct SportsHomeCard: View {
    @Environment(\.prismCardWidth) private var width
    let fixture: SportsFixture
    let now: Date
    let action: () -> Void

    var body: some View {
        let broadcasts = fixture.liveBroadcasts(at: now)
        let cardWidth = width ?? PrismMetrics.wideCardWidth
        let channel = broadcasts.first?.channel.name ?? fixture.broadcasts.first?.channel.name

        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                SportsEventPoster(fixture: fixture, now: now, width: cardWidth, includesDay: true)
                    .overlay(alignment: .topTrailing) {
                        if !broadcasts.isEmpty {
                            Image(systemName: broadcasts.count == 1 ? "play.fill" : "ellipsis")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .background(.black.opacity(0.45), in: .circle)
                                .prismGlass(.dark, in: .circle)
                                .padding(12)
                        }
                    }

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fixture.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if let score = fixture.scoreline {
                        Text(score)
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .fixedSize()
                    }
                }

                Text(channel ?? fixture.competition)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.top, -6)
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .frame(width: cardWidth, alignment: .leading)
        }
        .buttonStyle(CardButtonStyle(hoverScale: 1.025, shadow: false))
        .accessibilityLabel(fixture.title)
        .accessibilityValue([
            SportsTypography.dayAndHour(fixture.startsAt, relativeTo: now), fixture.state(at: now), fixture.scoreline, channel,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(broadcasts.count == 1 ? "Regarder la diffusion" : "Ouvrir la rubrique Sport")
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
