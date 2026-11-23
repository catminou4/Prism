import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

struct SportsFeature: View {
    @Environment(\.isPageActive) private var isActive
    let fixture: SportsFixture
    let now: Date
    let size: CGSize

    var body: some View {
        let broadcasts = fixture.liveBroadcasts(at: now)
        SportsFeatureBackdrop(fixture: fixture, size: size)
            .backgroundExtensionEffect(isEnabled: isActive)
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        SportsTimingPill(fixture: fixture, now: now, includesDay: true)
                        Text(fixture.competition)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }

                    Text(fixture.title)
                        .font(.system(size: min(50, max(32, size.width * 0.049)), weight: .bold))
                        .tracking(-1.6)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .accessibilityAddTraits(.isHeader)

                    if let score = fixture.scoreline {
                        Text(score)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.16), in: .capsule)
                            .accessibilityLabel("Score : \(score)")
                    }

                    if let channel = fixture.channelSummary {
                        Label(channel, systemImage: "tv")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }

                    if !broadcasts.isEmpty {
                        SportsWatchControl(fixture: fixture, broadcasts: broadcasts, prominent: true)
                            .padding(.top, 4)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: size.width * 0.54, alignment: .leading)
                .padding(.horizontal, PrismMetrics.contentMargin)
                .padding(.vertical, 32)
            }
            .accessibilityElement(children: .contain)
    }
}

struct SportsFeatureBackdrop: View {
    let fixture: SportsFixture
    let size: CGSize

    var body: some View {
        SportsArtwork(fixture: fixture, size: size, placement: .feature)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.82), location: 0),
                        .init(color: .black.opacity(0.72), location: 0.31),
                        .init(color: .black.opacity(0.20), location: 0.65),
                        .init(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing
                )
            }
            .accessibilityHidden(true)
    }
}

struct SportsEventCard: View {
    let fixture: SportsFixture
    let now: Date
    let width: CGFloat

    var body: some View {
        let broadcasts = fixture.liveBroadcasts(at: now)
        VStack(alignment: .leading, spacing: 10) {
            SportsEventPoster(fixture: fixture, now: now, width: width, aspectRatio: 2)

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    if fixture.showsScore, let event = fixture.event {
                        SportsTeamLine(team: event.home)
                        SportsTeamLine(team: event.away)
                        if event.league == .boxing, event.status == .final, let result = event.resultSummary {
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        Text(fixture.title)
                            .font(.headline)
                            .lineLimit(2)
                    }

                    Text([fixture.competition, fixture.channelSummary].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SportsWatchControl(fixture: fixture, broadcasts: broadcasts)
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// Shared artwork and timing for the programme grid and the Accueil shelf.
struct SportsEventPoster: View {
    let fixture: SportsFixture
    let now: Date
    let width: CGFloat
    var includesDay = false
    var aspectRatio = PrismMetrics.wideAspectRatio

    var body: some View {
        let size = CGSize(width: width, height: (width / aspectRatio).rounded())
        SportsArtwork(fixture: fixture, size: size)
            .overlay(alignment: .topLeading) {
                SportsTimingPill(fixture: fixture, now: now, includesDay: includesDay)
                    .padding(12)
            }
            .clipShape(.rect(cornerRadius: PrismMetrics.wideRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PrismMetrics.wideRadius)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

private struct SportsTimingPill: View {
    let fixture: SportsFixture
    let now: Date
    let includesDay: Bool

    var body: some View {
        let isLive = fixture.isAiring(at: now)
        let time = includesDay
            ? SportsTypography.dayAndHour(fixture.startsAt, relativeTo: now)
            : SportsTypography.hour(fixture.startsAt)

        HStack(spacing: 6) {
            if isLive {
                LiveBadge(pulsing: false)
                if let clock = fixture.event?.displayClock, !clock.isEmpty {
                    Text(fixture.state(at: now))
                }
            } else {
                Text(time)
                if fixture.state(at: now) != "À venir" {
                    Text("·")
                    Text(fixture.state(at: now))
                }
            }
        }
        .font(.caption.weight(.semibold).monospacedDigit())
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(.black.opacity(0.48), in: .capsule)
        .prismGlass(.dark, in: .capsule)
        .accessibilityElement(children: .combine)
    }
}

private struct SportsWatchControl: View {
    @Environment(AppModel.self) private var app
    @Environment(\.playPrismItem) private var playItem
    let fixture: SportsFixture
    let broadcasts: [SportsBroadcast]
    var prominent = false

    var body: some View {
        let playback = SportsPlayback(app: app, play: playItem)
        if let broadcast = broadcasts.first, broadcasts.count == 1 {
            if prominent {
                PrimaryCapsuleButton("Regarder", systemImage: "play.fill", minWidth: 0) { playback(broadcast) }
                    .help("Regarder sur \(broadcast.channel.name)")
            } else {
                GlassCircleButton(systemName: "play.fill", accessibilityLabel: "Regarder \(fixture.title)") { playback(broadcast) }
                    .help("Regarder sur \(broadcast.channel.name)")
            }
        } else if !broadcasts.isEmpty {
            Menu {
                ForEach(broadcasts) { broadcast in
                    Button(broadcast.channel.name) { playback(broadcast) }
                }
            } label: {
                if prominent {
                    GlassCapsuleLabel(title: "Regarder", systemImage: "play.fill")
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: PrismMetrics.toolbarButtonSize, height: PrismMetrics.toolbarButtonSize)
                        .contentShape(.circle)
                }
            }
            .modifier(SportsGlassMenu(style: prominent ? .dark : .regular, circular: !prominent))
            .accessibilityLabel("Choisir une chaîne pour \(fixture.title)")
            .help("Choisir une chaîne")
        }
    }
}

private struct SportsTeamLine: View {
    let team: SportsTeam

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
            if let score = team.score {
                Spacer(minLength: 8)
                Text(score.formatted())
                    .font(.headline.monospacedDigit())
                    .accessibilityLabel("\(score) points")
            }
        }
        .accessibilityElement(children: .combine)
    }
}
