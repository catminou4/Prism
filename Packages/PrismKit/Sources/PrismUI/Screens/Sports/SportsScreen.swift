import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

struct SportsScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(SportsPresentation.self) private var sports: SportsPresentation?
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var period: Period = .schedule
    @State private var sport: BroadcastSport?
    @State private var day: Date?
    @State private var scrollTarget: String?
    @State private var isRefreshingGuide = false
    @State private var showsGuidePrograms = false

    private enum Period: Hashable { case schedule, live }

    var body: some View {
        if let sports {
            VStack(alignment: .leading, spacing: 0) {
                header(now: sports.now)
                content(sports)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(SportsUpdates())
            .onChange(of: sports.destination, initial: true) { _, destination in
                guard let destination else { return }
                sport = nil
                period = destination.isLive ? .live : .schedule
                day = destination.day
                if let fixture = sports.fixtures.first(where: { $0.id == destination.fixtureID }), !fixture.isIdentifiedMatch {
                    showsGuidePrograms = true
                }
                scrollTarget = destination.fixtureID
                sports.destination = nil
            }
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                Text("Sport")
                    .font(.system(size: 36, weight: .bold))
                    .tracking(-1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 16)
                Picker("Affichage", selection: $period) {
                    Text("Programme").tag(Period.schedule)
                    Text("En direct").tag(Period.live)
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .labelsHidden()
                .fixedSize()

                GlassCircleButton(systemName: "arrow.clockwise", accessibilityLabel: "Actualiser le guide TV", action: refreshGuide)
                    .disabled(isRefreshingGuide || app.isRefreshingGuide || app.sources.isEmpty)
                    .help("Actualiser le guide TV")
            }

            HStack(spacing: 12) {
                Picker("Discipline", selection: $sport) {
                    Text("Tous").tag(nil as BroadcastSport?)
                    ForEach(BroadcastSport.allCases, id: \.self) { value in
                        Text(value.displayName).tag(Optional(value))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                if period == .schedule {
                    let today = Calendar.current.startOfDay(for: now)
                    let window = SportsPresentation.scheduleWindow(from: today)
                    DatePicker(
                        "Date du programme", selection: dayBinding(today: today, in: window),
                        in: window.start...window.end.addingTimeInterval(-1), displayedComponents: .date
                    )
                    .labelsHidden()
                    .environment(\.locale, Locale(identifier: "fr-FR"))
                    .fixedSize()
                }
            }
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    @ViewBuilder private func content(_ sports: SportsPresentation) -> some View {
        let calendar = Calendar.current
        let date = sports.now
        let today = calendar.startOfDay(for: date)
        let selected = dayBinding(today: today, in: SportsPresentation.scheduleWindow(from: today)).wrappedValue
        let entries = sports.fixtures.filter { fixture in
            guard sport == nil || fixture.sport == sport else { return false }
            switch period {
            case .schedule: return calendar.isDate(fixture.startsAt, inSameDayAs: selected)
            case .live: return fixture.isLive(at: date) || !fixture.liveBroadcasts(at: date).isEmpty
            }
        }

        if !sports.hasLoaded && entries.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Chargement du programme sportif")
        } else if entries.isEmpty {
            emptyState(sports)
        } else {
            let matches = entries.filter(\.isIdentifiedMatch)
            let featured = matches.isEmpty ? entries.filter { !$0.isCompanionProgram } : matches
            let extra = matches.isEmpty ? entries.filter(\.isCompanionProgram) : entries.filter { !$0.isIdentifiedMatch }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if period == .schedule {
                            Text(SportsTypography.longDay(selected))
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                                .padding(.bottom, 10)
                        }
                        ForEach(featured) { fixture in
                            scheduleRow(fixture, now: date)
                        }
                        if !extra.isEmpty {
                            Button {
                                showsGuidePrograms.toggle()
                            } label: {
                                Label(showsGuidePrograms ? "Masquer les autres programmes" : "Autres programmes du guide",
                                      systemImage: showsGuidePrograms ? "chevron.up" : "chevron.down")
                                    .font(.callout.weight(.medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 16)
                            if showsGuidePrograms {
                                ForEach(extra) { fixture in
                                    scheduleRow(fixture, now: date)
                                }
                            }
                        }
                        if sports.liveStatus == .needsKey {
                            Button("Configurer les scores en direct", systemImage: "gearshape") { openSettings() }
                                .buttonStyle(.link)
                                .padding(.top, 22)
                        } else if sports.liveStatus == .unavailable {
                            Text("Scores en direct temporairement indisponibles")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.top, 22)
                        }
                    }
                    .padding(.horizontal, PrismMetrics.contentMargin)
                    .padding(.bottom, 32)
                }
                .onChange(of: scrollTarget, initial: true) { _, target in
                    guard let target else { return }
                    withAnimation(reduceMotion ? nil : PrismMotion.standard) { reader.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
    }

    private func scheduleRow(_ fixture: SportsFixture, now: Date) -> some View {
        VStack(spacing: 0) {
            SportsScheduleRow(fixture: fixture, now: now)
            Divider()
        }
        .id(fixture.id)
    }

    private func emptyState(_ sports: SportsPresentation) -> some View {
        let missingGuide = app.guide.isEmpty && sports.fixtures.isEmpty
        return EmptyStateView(
            symbol: "sportscourt",
            title: missingGuide ? "Programme sportif indisponible" : (period == .live ? "Aucune rencontre en direct" : "Aucune rencontre à cette date"),
            message: missingGuide ? "Actualisez le guide TV ou configurez les scores dans Réglages." : nil,
            actionTitle: missingGuide && sports.liveStatus == .needsKey ? "Ouvrir les réglages" : nil,
            action: { openSettings() }
        )
    }

    private func dayBinding(today: Date, in window: DateInterval) -> Binding<Date> {
        Binding(get: {
            if let day, day >= window.start, day < window.end { return day }
            return today
        }, set: { day = Calendar.current.startOfDay(for: $0) })
    }

    private func refreshGuide() {
        Task {
            isRefreshingGuide = true
            defer { isRefreshingGuide = false }
            for source in app.sources where source.isEnabled {
                guard !Task.isCancelled else { return }
                await app.refreshGuide(for: source.id)
            }
        }
    }
}

private struct SportsScheduleRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.playPrismItem) private var playItem
    let fixture: SportsFixture
    let now: Date

    var body: some View {
        let live = fixture.liveBroadcasts(at: now)
        HStack(alignment: .center, spacing: 20) {
            SportsArtwork(fixture: fixture, size: CGSize(width: 192, height: 108))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 9) {
                    Text(SportsTypography.hour(fixture.startsAt))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Text(fixture.competition)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let event = fixture.event {
                    SportsTeamLine(team: event.home, showsScore: fixture.showsScore)
                    SportsTeamLine(team: event.away, showsScore: fixture.showsScore)
                    if event.league == .boxing, event.status == .final, let result = event.resultSummary {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(fixture.title).font(.headline).lineLimit(2)
                }
                HStack(spacing: 8) {
                    SportsStatus(fixture: fixture, now: now)
                    if !fixture.broadcasts.isEmpty {
                        Text(fixture.broadcasts.map(\.channel.name).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: 300, alignment: .leading)

            Spacer(minLength: 0)
            playControl(live)
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func playControl(_ broadcasts: [SportsBroadcast]) -> some View {
        let playback = SportsPlayback(app: app, play: playItem)
        if let broadcast = broadcasts.first, broadcasts.count == 1 {
            GlassCapsuleButton(title: "Regarder", systemImage: "play.fill", trailingChevron: false, style: .regular) {
                playback(broadcast)
            }
            .help("Regarder sur \(broadcast.channel.name)")
        } else if !broadcasts.isEmpty {
            Menu {
                ForEach(broadcasts) { broadcast in
                    Button(broadcast.channel.name) { playback(broadcast) }
                }
            } label: {
                GlassCapsuleLabel(title: "Regarder", systemImage: "play.fill")
                    .prismGlass(.regular, in: .capsule, interactive: true)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private extension SportsFixture {
    var isIdentifiedMatch: Bool { event != nil || (isNamedBroadcast && !isCompanionProgram) }
}
