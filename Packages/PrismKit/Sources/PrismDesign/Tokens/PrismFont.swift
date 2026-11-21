import SwiftUI

/// Type scale (SF Pro), measured on the Apple TV app for Mac.
///
/// Fonts cannot carry tracking; use the companion `*Tracking` constants with `.tracking(_:)`.
nonisolated public enum PrismFont {
    // MARK: Hero
    /// Hero title text when no logo image exists (≈ 56–64 bold, scaled down to fit).
    public static let heroTitle: Font = .system(size: 60, weight: .bold)
    public static let heroTitleTracking: CGFloat = -1.5
    /// Hero metadata line: `[glyph] Série TV · Thriller · Mystery [16+]`.
    public static let heroMeta: Font = .system(size: 13)
    /// Hero description (2 lines + PLUS).
    public static let heroBody: Font = .system(size: 13)
    /// Emphasised prefix inside the hero description (`S1, É1 · Titre :`).
    public static let heroBodyEmphasis: Font = .system(size: 13, weight: .semibold)
    /// Tech line `2022 · 57 min` + badges.
    public static let techLine: Font = .system(size: 13)
    /// Extra line spacing of multi-line hero text (Apple: 13 pt text on an 18 pt line).
    public static let heroLineSpacing: CGFloat = 2
    /// Trailing `Avec … / Réalisation …` block.
    public static let heroCredits: Font = .system(size: 13)
    public static let heroCreditsEmphasis: Font = .system(size: 13, weight: .medium)

    // MARK: Shelves
    public static let shelfTitle: Font = .system(size: 17, weight: .bold)
    public static let shelfChevron: Font = .system(size: 14, weight: .bold)
    public static let shelfSubtitle: Font = .system(size: 13)
    /// Section titles inside detail pages (`Informations`, `Langues`).
    public static let sectionTitle: Font = .system(size: 17, weight: .bold)

    // MARK: Cards
    /// Caption on wide cards (`In Watchlist`, `S1, É1 · 23 min`).
    public static let cardCaption: Font = .system(size: 13, weight: .medium)
    /// Secondary metadata on cards and grid titles' subtitle.
    public static let cardMeta: Font = .system(size: 11, weight: .medium)
    /// Grid title under a poster.
    public static let cardTitle: Font = .system(size: 13, weight: .semibold)
    /// `ÉPISODE 1`.
    public static let episodeEyebrow: Font = .system(size: 11)
    public static let episodeTitle: Font = .system(size: 15, weight: .medium)
    public static let episodeBody: Font = .system(size: 13)
    public static let episodeDuration: Font = .system(size: 13, weight: .medium)
    /// Top 10 rank numbers.
    public static let rankNumber: Font = .system(size: 48, weight: .heavy)
    public static let rankNumberTracking: CGFloat = -2
    public static let tileTitle: Font = .system(size: 15, weight: .bold)
    public static let personName: Font = .system(size: 12, weight: .medium)
    public static let personRole: Font = .system(size: 11)
    public static let sourceName: Font = .system(size: 15, weight: .semibold)
    public static let aboutTitle: Font = .system(size: 17, weight: .bold)
    public static let aboutGenres: Font = .system(size: 10, weight: .semibold)
    public static let infoLabel: Font = .system(size: 12, weight: .medium)
    public static let infoValue: Font = .system(size: 12)

    // MARK: Controls
    public static let primaryButton: Font = .system(size: 15, weight: .semibold)
    /// Label of the 40 pt capsule (onboarding, sheets).
    public static let largeButton: Font = .system(size: 16, weight: .semibold)
    public static let capsuleButton: Font = .system(size: 13, weight: .semibold)
    public static let chip: Font = .system(size: 13, weight: .semibold)
    public static let plusPill: Font = .system(size: 12, weight: .medium)
    public static let badge: Font = .system(size: 9.5, weight: .bold)
    public static let labelPill: Font = .system(size: 11, weight: .semibold)
    public static let toolbarTitle: Font = .system(size: 13, weight: .semibold)

    // MARK: Player
    public static let playerTitle: Font = .system(size: 22, weight: .bold)
    public static let playerSubtitle: Font = .system(size: 13, weight: .medium)
    /// Timecodes (`00:27`, `-02:09`) with monospaced digits.
    public static let timecode: Font = .system(size: 11, weight: .medium).monospacedDigit()

    // MARK: Empty states / onboarding
    public static let emptyTitle: Font = .system(size: 22, weight: .bold)
    public static let emptyMessage: Font = .system(size: 13)
    public static let onboardingHeadline: Font = .system(size: 34, weight: .bold)
}
