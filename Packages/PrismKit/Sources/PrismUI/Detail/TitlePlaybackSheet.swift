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

/// Immersive Apple TV–style playback sheet for a film or an episode: full-bleed artwork,
/// title, facts, synopsis and play actions, then the language / edition picker as tiles.
struct TitlePlaybackSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: MediaTitle
    let selection: TitlePlaybackSelection
    let hero: PlaybackSheetHero
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

    private static let size = CGSize(width: 1040, height: 652)
    private static let heroHeight: CGFloat = 446
    private static let margin: CGFloat = 40

    init(
        title: MediaTitle,
        selection: TitlePlaybackSelection,
        hero: PlaybackSheetHero,
        repository: DetailRepository,
        resumePosition: @escaping (TitlePlaybackOption) -> TimeInterval?,
        onPlay: @escaping (TitlePlaybackOption, TimeInterval?) -> Void
    ) {
        self.title = title
        self.selection = selection
        self.hero = hero
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
        VStack(alignment: .leading, spacing: 0) {
            heroInfo(selected: selected)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .frame(height: Self.heroHeight)
            editionPicker(section, selected: selected)
                .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background { PlaybackSheetBackdrop(hero: hero, size: Self.size, heroHeight: Self.heroHeight) }
        .overlay(alignment: .top) { toolbar }
        .environment(\.colorScheme, .dark)
        .presentationBackground(.black)
        .task(id: hero.synopsisCandidates) {
            let value = await DetailPresentation.synopsis(hero.synopsisCandidates)
            if !Task.isCancelled { synopsis = value }
        }
        .task(id: loadingRevision) { await resolveEditions() }
    }

    // MARK: Hero

    private var toolbar: some View {
        HStack(spacing: 12) {
            if selection.episode != nil {
                Text(title.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 1)
            }
            Spacer(minLength: 0)
            GlassCircleButton(systemName: "xmark", style: .dark, accessibilityLabel: "Fermer", action: cancel)
                .keyboardShortcut(.cancelAction)
                .help("Fermer")
        }
        .padding(.leading, Self.margin)
        .padding(.trailing, 18)
        .padding(.top, 18)
    }

    private func heroInfo(selected: TitlePlaybackOption?) -> some View {
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
                ExpandableText(synopsis, lineLimit: 3, font: .system(size: 14), popoverTitle: hero.name, lineSpacing: 3)
                    .padding(.top, 12)
            }
            actions(selected: selected)
                .padding(.top, 22)
        }
        .frame(maxWidth: 600, alignment: .leading)
        .padding(.horizontal, Self.margin)
        .padding(.bottom, 24)
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
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text(visible.count.formatted())
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                    .accessibilityLabel(visible.count == 1 ? "1 édition" : "\(visible.count) éditions")
                if groups.count == 1, let source = groups.first?.source {
                    sourceLabel(source)
                        .foregroundStyle(.white.opacity(0.5))
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
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: PlaybackEditionTile.size.height)
                .padding(.horizontal, 18)
                .background(.white.opacity(0.06), in: .rect(cornerRadius: 14))
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
                        .padding(.vertical, 6)
                    }
                    .contentMargins(.horizontal, Self.margin, for: .scrollContent)
                    .scrollIndicators(.hidden)
                    .scrollEdgeEffectStyle(.soft, for: [.leading, .trailing])
                    .frame(height: PlaybackEditionTile.size.height + 12)
                    .onAppear {
                        if let id = selected?.id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .id(language)
            }

            HStack(spacing: 18) {
                if selected?.titleEdition.edition.key == "MULTI" {
                    Label("Les pistes audio se choisissent dans le lecteur.", systemImage: "waveform")
                }
                connectionStatus
            }
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .frame(height: 22)
            .padding(.horizontal, Self.margin)
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
        .foregroundStyle(active ? Color.black : Color.white.opacity(0.75))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(active ? Color.white : .clear, in: .capsule)
        .prismGlass(.dark, interactive: true)
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
