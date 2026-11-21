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

    @State private var discovered: [TitlePlaybackOption] = []
    @State private var failures: [TitleEdition] = []
    @State private var language: PlaybackEdition?
    @State private var selectedID: ContentID?
    @State private var isLoading = false
    @State private var loadingRevision = 0

    private var options: [TitlePlaybackOption] { selection.options + discovered }
    private var visibleOptions: [TitlePlaybackOption] {
        options.filter { language == nil || $0.titleEdition.edition == language }
    }
    private var languages: [PlaybackEdition] {
        var seen: Set<PlaybackEdition> = []
        return options.map(\.titleEdition.edition).filter { seen.insert($0).inserted }
    }
    private var selected: TitlePlaybackOption? {
        let list = visibleOptions
        return list.first { $0.id == selectedID }
            ?? list.first { $0.id == selection.preferred }
            ?? list.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            fields
            Divider()
            footer
        }
        .frame(width: 540)
        .task(id: loadingRevision) { await resolveEditions() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            RemoteImage(
                url: title.posterURL, size: CGSize(width: 52, height: 78),
                placeholderSeed: title.id.rawValue, placeholderTitle: title.title, placeholderStyle: .monogram
            )
            .clipShape(.rect(cornerRadius: 7))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("Choisir une édition")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(title.title).font(.headline)
                if let subtitle = selection.subtitle {
                    Text(subtitle).foregroundStyle(.secondary)
                }
            }
            .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(24)
    }

    private var fields: some View {
        let visible = visibleOptions
        let activeID = selected?.id
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Langue ou version", selection: $language) {
                Text("Toutes les éditions").tag(nil as PlaybackEdition?)
                ForEach(languages, id: \.key) { language in
                    Text(language.title).tag(Optional(language))
                }
            }
            .pickerStyle(.menu)
            .onChange(of: language) { _, _ in selectedID = nil }

            Text("Sources disponibles")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(visible) { option in
                        editionRow(option, isSelected: option.id == activeID)
                    }
                }
                .padding(2)
            }
            .frame(height: CGFloat(min(max(visible.count, 1), 4)) * 60)
            .defaultScrollAnchor(.top)

            if selected?.titleEdition.edition.key == "MULTI" {
                Label("Les pistes audio se choisissent dans le lecteur.", systemImage: "waveform")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

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
                }
                .font(.callout)
            }
        }
        .padding(24)
    }

    private func editionRow(_ option: TitlePlaybackOption, isSelected: Bool) -> some View {
        let edition = option.titleEdition
        let tint = PrismTint(rawValue: edition.source.tint.rawValue) ?? .blue
        return Button {
            selectedID = option.id
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
                Circle().fill(tint.color)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(edition.source.name).fontWeight(.semibold)
                    Text(edition.edition.title).font(.callout).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if !option.label.isEmpty {
                    Text(option.label)
                        .font(.system(.caption, design: .monospaced, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 50)
            .background(isSelected ? Color.accentColor.opacity(0.13) : PrismColors.panelFill, in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 0.4 : 0), lineWidth: 1)
            }
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(edition.variant.rawName)
    }

    private var footer: some View {
        let position = selected.flatMap(resumePosition)
        return HStack(spacing: 10) {
            Button("Annuler", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if position != nil, let selected {
                Button("Depuis le début") { confirm(selected, position: nil) }
            }
            Button {
                if let selected { confirm(selected, position: position) }
            } label: {
                Label(position == nil ? "Lire" : "Reprendre", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selected == nil)
        }
        .padding(20)
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
            discovered.append(contentsOf: results.compactMap(\.option))
            failures.append(contentsOf: results.filter(\.failed).map { editions[$0.index] })
        }
    }

    private nonisolated struct EditionResult: Sendable {
        let index: Int
        var option: TitlePlaybackOption?
        var failed = false
    }
}
