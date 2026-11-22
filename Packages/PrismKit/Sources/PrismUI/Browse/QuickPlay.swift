import Foundation
import PrismCore
import PrismData

/// One-click playback of a film from a card or the hero, without opening its page.
///
/// Picks the edition the user chose last time, otherwise the best edition in the preferred
/// audio language, and resumes where the user stopped.
@MainActor
enum QuickPlay {
    private static let frenchTags: Set<String> = ["FR", "FRA", "FRENCH", "VF", "VFF", "VFQ", "VFI", "TRUEFRENCH", "MULTI"]
    private static let englishTags: Set<String> = ["EN", "ENG", "ENGLISH", "VO", "VOSTFR", "MULTI"]

    static func canPlay(_ title: MediaTitle, app: AppModel) -> Bool {
        title.kind == .movie && title.variants.contains { variant in
            variant.movie != nil && app.source(variant.sourceID)?.isEnabled == true
        }
    }

    static func option(for title: MediaTitle, app: AppModel) -> TitlePlaybackOption? {
        guard title.kind == .movie else { return nil }
        let enabled = title.variants.filter { app.source($0.sourceID)?.isEnabled == true }
        guard !enabled.isEmpty else { return nil }
        let preferredID = app.library.preferredVariant(for: title.id)
        let languages = app.homeAudioLanguages
        let ranked = enabled.sorted { lhs, rhs in
            let left = rank(lhs, preferredID: preferredID, languages: languages)
            let right = rank(rhs, preferredID: preferredID, languages: languages)
            return left != right ? left > right : lhs.quality > rhs.quality
        }
        for variant in ranked {
            guard let source = app.source(variant.sourceID),
                  let option = TitlePlaybackOption(edition: TitleEdition(
                      variant: variant, source: source, categoryLanguages: app.catalog.providerLanguages(for: variant)
                  )) else { continue }
            return option
        }
        return nil
    }

    static func play(_ option: TitlePlaybackOption, title: MediaTitle, app: AppModel, playItem: PrismPlaybackAction) {
        let exact = app.library.progress(for: option.contentID)
        let position = option.resumePosition(exact: exact, equivalent: app.library.latestProgress(forTitle: title.id))
        app.library.setPreferredVariant(option.id, for: title.id)
        playItem(option.playbackItem(for: title, position: position), .title(title.id), option.contentID, seriesEditionID: nil)
    }

    private static func rank(_ variant: MediaVariant, preferredID: ContentID?, languages: Set<HomeAudioLanguage>) -> Int {
        if variant.id == preferredID { return 100 }
        let tags = Set(variant.tags.map { $0.uppercased() })
        var score = 0
        if languages.contains(.french), !tags.isDisjoint(with: frenchTags) { score += 20 }
        if languages.contains(.english), !tags.isDisjoint(with: englishTags) { score += languages.contains(.french) ? 8 : 20 }
        score += variant.quality.rawValue
        return score
    }
}
