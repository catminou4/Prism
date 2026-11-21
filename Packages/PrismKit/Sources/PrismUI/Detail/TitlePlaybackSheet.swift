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

    var subtitle: String? {
        episode.map { "\(EpisodeCoordinate($0).label) · \($0.title)" }
    }
}

struct TitlePlaybackSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: MediaTitle
    let selection: TitlePlaybackSelection
    let repository: DetailRepository
    let resumePosition: (TitlePlaybackOption) -> TimeInterval?
    let onPlay: (TitlePlaybackOption, TimeInterval?) -> Void

    @State private var choices: PlaybackSheetChoices
    @State private var failures: [TitleEdition] = []
    @State private var language = PlaybackSheetFilter.all
    @State private var selectedID: ContentID?
    @State private var isLoading = false
    @State private var loadingRevision = 0
    @FocusState private var focusedOption: ContentID?

    init(
        title: MediaTitle,
        selection: TitlePlaybackSelection,
        repository: DetailRepository,
        resumePosition: @escaping (TitlePlaybackOption) -> TimeInterval?,
        onPlay: @escaping (TitlePlaybackOption, TimeInterval?) -> Void
    ) {
        self.title = title
        self.selection = selection
        self.repository = repository
        self.resumePosition = resumePosition
        self.onPlay = onPlay
        _choices = State(initialValue: PlaybackSheetChoices(selection.options))
    }

    var body: some View {
        let visible = choices[language]
        let selected = visible.first { $0.id == selectedID }
            ?? visible.first { $0.id == selection.preferred }
            ?? visible.first
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 14) {
                if choices.filters.count > 1 { languageFilters }
                editionList(visible, activeID: selected?.id)
                if selected?.titleEdition.edition.key == "MULTI" {
                    Label("Les pistes audio se choisissent dans le lecteur.", systemImage: "waveform")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                connectionStatus
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            Divider()
            footer(selected)
        }
        .frame(width: 552)
        .task(id: loadingRevision) { await resolveEditions() }
    }

    private var header: some View {
        HStack(spacing: 14) {
            let posterShape = RoundedRectangle(cornerRadius: PrismMetrics.smallArtworkRadius)
            RemoteImage(
                url: title.posterURL, size: CGSize(width: 44, height: 66),
                placeholderSeed: title.id.rawValue, placeholderTitle: title.title, placeholderStyle: .monogram
            )
            .clipShape(posterShape)
            .overlay { posterShape.strokeBorder(.primary.opacity(0.09), lineWidth: 1) }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Sources et langues")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(title.title)
                    .font(.system(size: 23, weight: .semibold))
                    .lineLimit(2)
                if let subtitle = selection.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 17)
    }

    private var languageFilters: some View {
        let filters = choices.filters
        return VStack(alignment: .leading, spacing: 7) {
            Text("Langues et versions")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                if filters.count <= 4 {
                    filterBar(filters, overflow: [])
                }
                let inline = Array(filters.filter { !$0.id.hasPrefix("version-") }.prefix(2))
                filterBar(inline, overflow: filters.filter { !inline.contains($0) })
                filterBar([], overflow: filters)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Filtrer les éditions")
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
        .foregroundStyle(active ? .primary : .secondary)
        .padding(.horizontal, 12)
        .frame(height: 31)
        .background(active ? Color.primary.opacity(0.10) : .clear, in: .capsule)
        .prismGlass(interactive: true)
        .contentShape(.capsule)
    }

    private func setFilter(_ filter: PlaybackSheetFilter) {
        guard language != filter else { return }
        language = filter
        selectedID = nil
    }

    private func editionList(_ visible: [TitlePlaybackOption], activeID: ContentID?) -> some View {
        let groups = PlaybackSourceGroup.grouped(visible)
        let ordered = groups.flatMap(\.options)
        let expected = selection.options.count + selection.otherEditions.count
        let rows = min(max(visible.count, expected > 0 && language == .all ? expected : 1), 5)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Éditions disponibles")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(visible.count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(visible.count == 1 ? "1 édition" : "\(visible.count) éditions")
                Spacer(minLength: 0)
                if groups.count == 1, let source = groups.first?.source {
                    sourceLabel(source)
                }
            }
            if visible.isEmpty {
                Text(isLoading ? "Recherche d’une édition disponible…" : "Aucune édition disponible.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                    .padding(.horizontal, 12)
                    .background(PrismColors.panelFill, in: .rect(cornerRadius: 12))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups) { group in
                                if groups.count > 1 {
                                    sourceLabel(group.source)
                                        .accessibilityAddTraits(.isHeader)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 7)
                                }
                                ForEach(group.options) { option in
                                    PlaybackSheetOptionRow(
                                        option: option, selected: option.id == activeID, focused: focusedOption == option.id,
                                        duplicateNumber: group.duplicateNumbers[option.id]
                                    ) {
                                        selectedID = option.id
                                        focusedOption = option.id
                                    }
                                    .focused($focusedOption, equals: option.id)
                                    .onKeyPress(.upArrow) { moveSelection(from: option.id, by: -1, options: ordered, proxy: proxy) }
                                    .onKeyPress(.downArrow) { moveSelection(from: option.id, by: 1, options: ordered, proxy: proxy) }
                                    .id(option.id)
                                }
                            }
                        }
                        .padding(4)
                    }
                    .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
                    .onAppear {
                        if let activeID { proxy.scrollTo(activeID, anchor: .center) }
                    }
                    .frame(height: CGFloat(rows) * 40 + 8 + (groups.count > 1 ? 28 : 0))
                }
                .id(language)
                .background(PrismColors.panelFill, in: .rect(cornerRadius: 12))
            }
        }
    }

    private func sourceLabel(_ source: Source) -> some View {
        Label(source.name, systemImage: "tv")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
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
        proxy.scrollTo(next)
        focusedOption = next
        return .handled
    }

    @ViewBuilder private var connectionStatus: some View {
        if isLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Vérification des autres éditions…")
            }
            .foregroundStyle(.secondary)
            .font(.callout)
        } else if !failures.isEmpty {
            HStack(spacing: 10) {
                Label("Certaines sources sont indisponibles.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Réessayer") { loadingRevision += 1 }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .font(.callout)
        }
    }

    private func footer(_ selected: TitlePlaybackOption?) -> some View {
        let position = selected.flatMap(resumePosition)
        return HStack(spacing: 8) {
            Button("Annuler", role: .cancel) { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: 8)
            if position != nil, let selected {
                Button("Depuis le début") { confirm(selected, position: nil) }
                    .buttonStyle(.glass)
            }
            Button {
                if let selected { confirm(selected, position: position) }
            } label: {
                Label(position == nil ? "Lire" : "Reprendre", systemImage: "play.fill")
            }
            .buttonStyle(.glassProminent)
            .tint(Color(white: 0.28))
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
        .controlSize(.large)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private func confirm(_ option: TitlePlaybackOption, position: TimeInterval?) {
        dismiss()
        onPlay(option, position)
    }

    private func resolveEditions() async {
        guard let episode = selection.episode else { return }
        let repository = repository
        let editions = loadingRevision == 0 ? selection.otherEditions : failures
        guard !editions.isEmpty else { return }
        let coordinate = EpisodeCoordinate(episode)
        isLoading = true
        failures = []
        defer { isLoading = false }
        // Bound remote requests and retain catalog/source order as results arrive.
        for start in stride(from: 0, to: editions.count, by: 4) {
            guard !Task.isCancelled else { return }
            let end = min(start + 4, editions.count)
            let results = await withTaskGroup(of: EditionResult.self) { group in
                for index in start..<end {
                    let edition = editions[index]
                    group.addTask {
                        guard let series = edition.variant.series else { return .init(index: index) }
                        do {
                            let detail = try await repository.seriesDetail(series, source: edition.source)
                            let match = detail.seasons.lazy
                                .filter { $0.number == coordinate.season }
                                .flatMap(\.episodes)
                                .first { EpisodeCoordinate($0) == coordinate }
                            let option = match.flatMap { TitlePlaybackOption(edition: edition, episode: $0) }
                            return .init(index: index, option: option)
                        } catch {
                            return .init(index: index, failed: true)
                        }
                    }
                }
                var values: [EditionResult] = []
                for await result in group { values.append(result) }
                return values.sorted { $0.index < $1.index }
            }
            guard !Task.isCancelled else { return }
            choices.append(results.compactMap(\.option))
            failures.append(contentsOf: results.filter(\.failed).map { editions[$0.index] })
        }
    }

    private nonisolated struct EditionResult: Sendable {
        let index: Int
        var option: TitlePlaybackOption?
        var failed = false
    }
}
