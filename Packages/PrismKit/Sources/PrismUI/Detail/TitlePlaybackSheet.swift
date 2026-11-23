import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

struct TitlePlaybackSelection: Identifiable {
    let id = UUID()
    let options: [TitlePlaybackOption]
    let otherEditions: [TitleEdition]
    let episode: Episode?
    let preferred: ContentID?
}

/// Apple TV–style playback sheet for a film or an episode, laid out like the detail page:
/// an always-dark hero (artwork, title, facts, synopsis, play actions), then — on the page
/// background, following the system appearance — the language / edition tiles and info columns.
struct TitlePlaybackSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: MediaTitle
    let selection: TitlePlaybackSelection
    let hero: PlaybackSheetHero
    let containerSize: CGSize
    let repository: DetailRepository
    let resumePosition: (TitlePlaybackOption) -> TimeInterval?
    let onPlay: (TitlePlaybackOption, TimeInterval?) -> Void

    @State private var choices: PlaybackSheetChoices
    @State private var failures: [TitleEdition] = []
    @State private var language = PlaybackSheetFilter.all
    @State private var selectedID: ContentID?
    @State private var isLoading = false
    @State private var loadingRevision = 0
    @State private var isClosing = false
    @State private var synopsis: String?
    @FocusState private var focusedOption: ContentID?

    private static let margin = PrismMetrics.contentMargin

    /// Large but still a sheet: inset from the detail page it covers.
    private static func size(for container: CGSize) -> CGSize {
        CGSize(
            width: min(1360, max(1000, container.width - 120)).rounded(),
            height: min(920, max(600, container.height - 110)).rounded()
        )
    }

    init(
        title: MediaTitle,
        selection: TitlePlaybackSelection,
        hero: PlaybackSheetHero,
        containerSize: CGSize,
        repository: DetailRepository,
        resumePosition: @escaping (TitlePlaybackOption) -> TimeInterval?,
        onPlay: @escaping (TitlePlaybackOption, TimeInterval?) -> Void
    ) {
        self.title = title
        self.selection = selection
        self.hero = hero
        self.containerSize = containerSize
        self.repository = repository
        self.resumePosition = resumePosition
        self.onPlay = onPlay
        _choices = State(initialValue: PlaybackSheetChoices(selection.options, followedBy: selection.otherEditions))
    }

    var body: some View {
        let section = choices.section(for: language)
        let visible = section.options
        let selected = visible.first { $0.id == selectedID }
            ?? visible.first { $0.id == selection.preferred }
            ?? visible.first
        let size = Self.size(for: containerSize)
        let heroHeight = min(620, max(420, (size.height * 0.6).rounded()))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection(selected: selected, size: CGSize(width: size.width, height: heroHeight))
                VStack(alignment: .leading, spacing: 34) {
                    editionPicker(section, selected: selected)
                    if let selected { informationColumns(selected) }
                }
                .padding(.top, 6)
                .padding(.bottom, 44)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: size.width, height: size.height)
        .background(PrismColors.pageBackground)
        .overlay(alignment: .topTrailing) {
            GlassCircleButton(systemName: "xmark", style: .dark, accessibilityLabel: "Fermer", action: cancel)
                .keyboardShortcut(.cancelAction)
                .help("Fermer")
                .environment(\.colorScheme, .dark)
                .padding(18)
        }
        .presentationBackground(PrismColors.pageBackground)
        .task(id: hero.synopsisCandidates) {
            let value = await DetailPresentation.synopsis(hero.synopsisCandidates)
            if !Task.isCancelled { synopsis = value }
        }
        .task(id: loadingRevision) { await resolveEditions() }
    }

    // MARK: Hero

    /// Same construction as the detail masthead: dark artwork + scrims, white text, 30 pt fade
    /// into the page background.
    private func heroSection(selected: TitlePlaybackOption?, size: CGSize) -> some View {
        ZStack(alignment: .bottomLeading) {
            HeroBackdrop(
                backdropURLs: hero.landscapes, seed: hero.seed, fallbackPosterURLs: [hero.poster].compactMap { $0 },
                leadingScrim: 0.75, artSize: size
            )
            .allowsHitTesting(false)
            heroInfo(selected: selected, width: min(620, size.width * 0.55))
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .topLeading) {
            if selection.episode != nil {
                Text(title.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
                    .padding(.leading, Self.margin)
                    .padding(.top, 26)
            }
        }
        .environment(\.colorScheme, .dark)
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [.clear, PrismColors.pageBackground], startPoint: .top, endPoint: .bottom)
                .frame(height: 30)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func heroInfo(selected: TitlePlaybackOption?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hero.eyebrow.uppercased(with: Locale(identifier: "fr-FR")))
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.7))
            heroTitle
                .padding(.top, 6)
            metaLine(selected: selected)
                .padding(.top, 10)
            if let synopsis {
                ExpandableText(synopsis, lineLimit: 3, font: .system(size: 14), moreTitle: "Plus", popoverTitle: hero.name, lineSpacing: 3)
                    .foregroundStyle(.white.opacity(0.91))
                    .padding(.top, 12)
            }
            actions(selected: selected)
                .padding(.top, 22)
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, Self.margin)
        .padding(.bottom, 44)
    }

    @ViewBuilder private var heroTitle: some View {
        let font = Font.system(size: 36, weight: .bold)
        if let logo = hero.logo {
            TitleLogo(url: logo, fallbackTitle: hero.name, maxSize: CGSize(width: 360, height: 96), fallbackFont: font)
        } else {
            Text(hero.name)
                .font(font)
                .tracking(-0.6)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 2)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func metaLine(selected: TitlePlaybackOption?) -> some View {
        let quality = (selected?.label ?? "").components(separatedBy: " · ")
            .filter { MediaBadge.isQualityLabel($0) }
        return HStack(spacing: 8) {
            if !hero.details.isEmpty {
                Text(hero.details.joined(separator: " · "))
            }
            if let rating = hero.rating {
                if !hero.details.isEmpty { Text("·") }
                Label(rating, systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
                    .accessibilityLabel("Note \(rating) sur 10")
            }
            if !quality.isEmpty {
                BadgeRow(quality.map { BadgeSpec($0, style: .filled) }, spacing: 4)
                    .padding(.leading, 2)
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private func actions(selected: TitlePlaybackOption?) -> some View {
        let position = selected.flatMap(resumePosition)
        let runtime = (selected?.duration.flatMap { $0 > 0 ? $0 : nil } ?? hero.runtimeSeconds).map(Double.init)
        let fraction = position.flatMap { position in runtime.map { min(max(position / $0, 0.02), 1) } }
        let remaining = position.flatMap { position in runtime.map { max(1, Int(($0 - position) / 60)) } }
        let playTitle = selection.episode == nil ? "Lecture" : "Lire l’épisode"
        let title = position == nil ? playTitle : remaining.map { "\($0) min restantes" } ?? "Reprendre"
        return HStack(spacing: 12) {
            PrimaryCapsuleButton(title, systemImage: "play.fill", progress: position == nil ? nil : fraction ?? 0, minWidth: 196) {
                if let selected { confirm(selected, position: position) }
            }
            .fixedSize()
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil || isClosing)
            if position != nil, let selected {
                GlassCapsuleButton(title: "Depuis le début", systemImage: "arrow.counterclockwise", trailingChevron: false) {
                    confirm(selected, position: nil)
                }
                .fixedSize()
                .disabled(isClosing)
            }
            if let selected {
                Text(selected.titleEdition.edition.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .padding(.leading, 4)
                    .accessibilityLabel("Édition choisie : \(selected.titleEdition.edition.title)")
            }
        }
    }

    // MARK: Editions

    private func editionPicker(_ section: PlaybackSheetChoices.Section, selected: TitlePlaybackOption?) -> some View {
        let visible = section.ordered
        let groups = section.groups
        let duplicates = groups.reduce(into: [ContentID: Int]()) { $0.merge($1.duplicateNumbers) { first, _ in first } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Text("Langue et version")
                    .font(PrismFont.sectionTitle)
                    .foregroundStyle(.primary)
                    .accessibilityAddTraits(.isHeader)
                Text(visible.count.formatted())
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(visible.count == 1 ? "1 édition" : "\(visible.count) éditions")
                if groups.count == 1, let source = groups.first?.source {
                    sourceLabel(source)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                Spacer(minLength: 12)
                if choices.filters.count > 1 {
                    filterBars
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Filtrer les éditions")
                }
            }
            .frame(minHeight: 32)
            .padding(.horizontal, Self.margin)

            if visible.isEmpty {
                HStack(spacing: 10) {
                    if isLoading { ProgressView().controlSize(.small) }
                    Text(isLoading ? "Recherche d’une édition disponible…" : "Aucune édition disponible.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: PlaybackEditionTile.size.height)
                .padding(.horizontal, 18)
                .background(PrismColors.panelFill, in: .rect(cornerRadius: 14))
                .padding(.horizontal, Self.margin)
                .padding(.vertical, 6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 12) {
                            ForEach(visible) { option in
                                PlaybackEditionTile(
                                    option: option, selected: option.id == selected?.id, focused: focusedOption == option.id,
                                    duplicateNumber: duplicates[option.id], showsSource: groups.count > 1
                                ) {
                                    selectedID = option.id
                                    focusedOption = option.id
                                }
                                .focused($focusedOption, equals: option.id)
                                .onKeyPress(.leftArrow) { moveSelection(from: option.id, by: -1, options: visible, proxy: proxy) }
                                .onKeyPress(.rightArrow) { moveSelection(from: option.id, by: 1, options: visible, proxy: proxy) }
                                .id(option.id)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .contentMargins(.horizontal, Self.margin, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .scrollEdgeEffectStyle(.soft, for: [.leading, .trailing])
                    .frame(height: PlaybackEditionTile.size.height + 20)
                    .onAppear {
                        if let id = selected?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .id(language)
            }

            let multi = selected?.titleEdition.edition.key == "MULTI"
            if multi || isLoading || !failures.isEmpty {
                HStack(spacing: 18) {
                    if multi {
                        Label("Les pistes audio se choisissent dans le lecteur.", systemImage: "waveform")
                    }
                    connectionStatus
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(height: 18)
                .padding(.horizontal, Self.margin)
            }
        }
    }

    private var filterBars: some View {
        let filters = choices.filters
        return ViewThatFits(in: .horizontal) {
            if filters.count <= 4 {
                filterBar(filters, overflow: [])
            }
            let inline = Array(filters.filter { !$0.id.hasPrefix("version-") }.prefix(2))
            filterBar(inline, overflow: filters.filter { !inline.contains($0) })
            filterBar([], overflow: filters)
        }
    }

    private func filterBar(_ inline: [PlaybackSheetFilter], overflow: [PlaybackSheetFilter]) -> some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach([.all] + inline) { filter in
                    let active = language == filter
                    Button { setFilter(filter) } label: {
                        filterLabel(filter.title, active: active, menu: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
                if !overflow.isEmpty {
                    let active = overflow.contains(language)
                    Menu {
                        ForEach(overflow) { filter in
                            Button { setFilter(filter) } label: {
                                if filter == language {
                                    Label(filter.title, systemImage: "checkmark")
                                } else {
                                    Text(filter.title)
                                }
                            }
                        }
                    } label: {
                        filterLabel(active ? language.title : "Autres", active: active, menu: true)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("Autres langues et versions")
                    .accessibilityValue(active ? language.title : "")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func filterLabel(_ title: String, active: Bool, menu: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title).lineLimit(1)
            if menu {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .font(.subheadline.weight(active ? .semibold : .medium))
        .foregroundStyle(active ? AnyShapeStyle(PrismColors.pageBackground) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(active ? Color.primary : .clear, in: .capsule)
        .prismGlass(interactive: true)
        .contentShape(.capsule)
    }

    private func setFilter(_ filter: PlaybackSheetFilter) {
        guard language != filter else { return }
        language = filter
        if !choices[filter].contains(where: { $0.id == selectedID }) { selectedID = nil }
        focusedOption = nil
    }

    private func sourceLabel(_ source: Source) -> some View {
        Label(source.name, systemImage: "tv")
            .font(.caption.weight(.medium))
            .lineLimit(1)
    }

    private func moveSelection(
        from id: ContentID, by step: Int, options: [TitlePlaybackOption], proxy: ScrollViewProxy
    ) -> KeyPress.Result {
        guard let index = options.firstIndex(where: { $0.id == id }), options.indices.contains(index + step) else {
            return .ignored
        }
        let next = options[index + step].id
        selectedID = next
        withAnimation(.smooth(duration: 0.3)) { proxy.scrollTo(next) }
        focusedOption = next
        return .handled
    }

    @ViewBuilder private var connectionStatus: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Vérification des autres éditions…")
            }
        } else if !failures.isEmpty {
            HStack(spacing: 10) {
                Label("Certaines sources sont indisponibles.", systemImage: "exclamationmark.circle")
                Button("Réessayer") {
                    guard !isLoading else { return }
                    isLoading = true
                    loadingRevision += 1
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
    }

    private func informationColumns(_ selected: TitlePlaybackOption) -> some View {
        let variant = selected.titleEdition.variant
        let technique = [
            InfoRow("Langue", selected.titleEdition.edition.title),
            InfoRow("Qualité", variant.quality.badge ?? ""),
            InfoRow("Conteneur", selected.container?.uppercased() ?? ""),
            InfoRow("Plage dynamique", variant.tags.contains("HDR") ? "HDR" : ""),
        ]
        let source = [
            InfoRow("Fournisseur", selected.titleEdition.source.name),
            InfoRow("Flux", variant.rawName),
        ]
        return HStack(alignment: .top, spacing: 40) {
            InfoColumn(title: "Informations", rows: hero.info)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            InfoColumn(title: "Technique", rows: technique)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            InfoColumn(title: "Source", rows: source)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, Self.margin)
    }

    // MARK: Actions

    private func cancel() {
        isClosing = true
        dismiss()
    }

    private func confirm(_ option: TitlePlaybackOption, position: TimeInterval?) {
        guard !isClosing else { return }
        isClosing = true
        dismiss()
        onPlay(option, position)
    }

    private func resolveEditions() async {
        let revision = loadingRevision
        let editions = revision == 0 ? selection.otherEditions : failures
        guard let episode = selection.episode, !editions.isEmpty, !Task.isCancelled else { return }
        isLoading = true
        failures = []
        await AlternateEditionResolver.resolve(editions, episode: episode, load: { [repository] series, source in
            try await repository.seriesDetail(series, source: source)
        }) { result in
            guard revision == loadingRevision, !isClosing, !Task.isCancelled else { return false }
            if let option = result.option {
                choices.append([option])
            } else if result.failed {
                failures.append(editions[result.index])
            }
            return true
        }
        if revision == loadingRevision, !Task.isCancelled { isLoading = false }
    }
}
