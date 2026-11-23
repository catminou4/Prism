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
    @Environment(\.isPageActive) private var isActive

    @State private var period: Period = .schedule
    @State private var sport: BroadcastSport?
    @State private var day: Date?
    @State private var scrollTarget: ScrollTarget?
    @State private var isRefreshingGuide = false
    @State private var showsGuidePrograms = false

    private enum Period: Hashable { case schedule, live }
    private enum ScrollTarget: Hashable { case top, fixture(String) }

    var body: some View {
        if let sports {
            let now = sports.now
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: now)
            let days = calendarDays(startingAt: today, calendar: calendar)
            let selected = day.flatMap { days.contains($0) ? $0 : nil } ?? today
            let schedule = SportsAgenda(
                fixtures: sports.fixtures, now: now, day: period == .schedule ? selected : nil, sport: sport,
                calendar: calendar
            )

            GeometryReader { geometry in
                let width = max(1, geometry.size.width - 2 * PrismMetrics.contentMargin)
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
                            if schedule.isEmpty {
                                emptyContent(sports)
                                    .frame(minHeight: max(0, geometry.size.height - 200))
                            } else {
                                agenda(schedule, now: now, width: width)
                                scoresNotice(sports)
                            }
                        }
                        .padding(.horizontal, PrismMetrics.contentMargin)
                        .padding(.top, 16)
                        .padding(.bottom, 44)
                        .id(ScrollTarget.top)
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .safeAreaBar(edge: .top, spacing: 0) {
                        header(selected: selected, days: days, today: today)
                    }
                    .task(id: scrollTarget) {
                        guard let scrollTarget else { return }
                        withAnimation(reduceMotion ? nil : PrismMotion.standard) {
                            reader.scrollTo(scrollTarget, anchor: scrollTarget == .top ? .top : .center)
                        }
                        self.scrollTarget = nil
                    }
                }
            }
            .modifier(SportsUpdates())
            .onChange(of: isActive ? sports.destination : nil, initial: true) { _, destination in
                guard let destination else { return }
                sport = nil
                period = destination.isLive ? .live : .schedule
                day = destination.day
                if sports.fixtures.contains(where: { $0.id == destination.fixtureID && !$0.isIdentifiedMatch }) {
                    showsGuidePrograms = true
                }
                scrollTarget = .fixture(destination.fixtureID)
                sports.destination = nil
            }
        }
    }

    private func header(selected: Date, days: [Date], today: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrowseHeading(title: "Sport")

                Button("Programme", systemImage: "calendar") { setPeriod(.schedule) }
                    .modifier(SportsPeriodStyle(isSelected: period == .schedule))
                Button("En direct", systemImage: "dot.radiowaves.left.and.right") { setPeriod(.live) }
                    .modifier(SportsPeriodStyle(isSelected: period == .live))

                GlassCircleButton(systemName: "arrow.clockwise", accessibilityLabel: "Actualiser le guide TV", action: refreshGuide)
                    .disabled(isRefreshingGuide || app.isRefreshingGuide || !app.sources.contains(where: \.isEnabled))
                    .help("Actualiser le guide TV")
                    .padding(.leading, 4)
                    .padding(.trailing, PrismMetrics.contentMargin)
            }

            HStack(spacing: 12) {
                ChipBar(items: Self.disciplines, selection: Binding(
                    get: { sport?.rawValue ?? "all" },
                    set: { value in
                        let next = value.flatMap(BroadcastSport.init(rawValue:))
                        guard sport != next else { return }
                        sport = next
                        scrollTarget = .top
                    }
                ))
                .accessibilityLabel("Disciplines")

                if period == .schedule {
                    dateMenu(selected: selected, days: days, today: today)
                        .padding(.trailing, PrismMetrics.contentMargin)
                }
            }
        }
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private static let disciplines = [ChipItem(id: "all", title: "Tous les sports")] + BroadcastSport.allCases.map {
        ChipItem(id: $0.rawValue, title: $0.displayName, systemImage: $0.symbol)
    }

    private func dateMenu(selected: Date, days: [Date], today: Date) -> some View {
        Menu {
            Picker("Date du programme", selection: Binding(get: { selected }, set: { date in
                guard selected != date else { return }
                day = date
                scrollTarget = .top
            })) {
                ForEach(days, id: \.self) { date in
                    Text(date == today ? "Aujourd’hui" : SportsTypography.longDay(date)).tag(date)
                }
            }
            .pickerStyle(.inline)
        } label: {
            GlassCapsuleLabel(
                title: selected == today ? "Aujourd’hui" : SportsTypography.longDay(selected),
                systemImage: "calendar"
            )
        }
        .modifier(SportsGlassMenu())
        .accessibilityLabel("Date du programme")
        .accessibilityValue(SportsTypography.longDay(selected))
    }

    private func calendarDays(startingAt today: Date, calendar: Calendar) -> [Date] {
        let window = SportsPresentation.scheduleWindow(from: today)
        let count = calendar.dateComponents([.day], from: window.start, to: window.end).day ?? 0
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: window.start) }
    }

    private func setPeriod(_ value: Period) {
        guard period != value else { return }
        period = value
        scrollTarget = .top
    }

    @ViewBuilder private func agenda(_ schedule: SportsAgenda, now: Date, width: CGFloat) -> some View {
        if let lead = schedule.featured {
            ZStack {
                SportsFeature(
                    fixture: lead, now: now,
                    size: CGSize(width: width, height: min(364, max(290, width * 0.31)))
                )
                .id(ScrollTarget.fixture(lead.id))
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : PrismMotion.quickFade, value: lead.id)
        }
        ForEach(schedule.sections) { section in
            VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
                ShelfHeader(section.kind.title)
                eventGrid(section.fixtures, now: now, width: width)
            }
        }

        if !schedule.otherPrograms.isEmpty {
            VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
                GlassCapsuleButton(
                    title: showsGuidePrograms ? "Masquer les autres programmes" : "Autres programmes du guide",
                    systemImage: showsGuidePrograms ? "chevron.up" : "chevron.down",
                    trailingChevron: false, style: .regular
                ) {
                    showsGuidePrograms.toggle()
                }

                if showsGuidePrograms {
                    eventGrid(schedule.otherPrograms, now: now, width: width)
                }
            }
        }
    }

    private func eventGrid(_ fixtures: [SportsFixture], now: Date, width: CGFloat) -> some View {
        let spacing = PrismMetrics.cardSpacing
        let columns = max(1, min(3, max(2, fixtures.count), Int((width + spacing) / (320 + spacing))))
        let cardWidth = (width - CGFloat(columns - 1) * spacing) / CGFloat(columns)
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing, alignment: .topLeading), count: columns),
            alignment: .leading, spacing: PrismMetrics.gridRowSpacing
        ) {
            ForEach(fixtures) { fixture in
                SportsEventCard(fixture: fixture, now: now, width: cardWidth)
                    .id(ScrollTarget.fixture(fixture.id))
            }
        }
    }

    @ViewBuilder private func emptyContent(_ sports: SportsPresentation) -> some View {
        if !sports.hasLoaded {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Chargement du programme sportif")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let missingGuide = app.guide.isEmpty && sports.fixtures.isEmpty
            EmptyStateView(
                symbol: "sportscourt",
                title: missingGuide ? "Programme sportif indisponible" : (period == .live ? "Aucune rencontre en direct" : "Aucune rencontre à cette date"),
                message: missingGuide ? "Actualisez le guide TV ou configurez les scores dans Réglages." : nil,
                actionTitle: missingGuide && sports.liveStatus == .needsKey ? "Ouvrir les réglages" : nil,
                action: { openSettings() }
            )
        }
    }

    @ViewBuilder private func scoresNotice(_ sports: SportsPresentation) -> some View {
        if sports.liveStatus == .needsKey {
            GlassCapsuleButton(
                title: "Configurer les scores en direct", systemImage: "gearshape", trailingChevron: false, style: .regular
            ) { openSettings() }
        } else if sports.liveStatus == .unavailable {
            Label("Scores en direct temporairement indisponibles", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshGuide() {
        isRefreshingGuide = true
        Task {
            defer { isRefreshingGuide = false }
            for source in app.sources where source.isEnabled {
                guard !Task.isCancelled else { return }
                await app.refreshGuide(for: source.id)
            }
        }
    }
}

private struct SportsPeriodStyle: ViewModifier {
    @Environment(\.prismSnapshotRendering) private var snapshot
    let isSelected: Bool

    func body(content: Content) -> some View {
        Group {
            if snapshot {
                content.buttonStyle(.plain)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .frame(height: PrismMetrics.toolbarButtonSize)
                    .background {
                        if isSelected { Capsule().fill(Color.accentColor) }
                        else { Capsule().fill(.clear).prismGlass() }
                    }
            } else if isSelected {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .fixedSize()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct SportsGlassMenu: ViewModifier {
    var style: PrismGlassStyle = .regular
    var circular = false

    func body(content: Content) -> some View {
        let menu = content
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        if circular {
            menu.prismGlass(style, in: .circle, interactive: true)
        } else {
            menu.prismGlass(style, in: .capsule, interactive: true)
        }
    }
}
