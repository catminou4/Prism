import SwiftUI

/// One trailing hero credit line: `Avec` + `Adam Scott, Britt Lower et Patricia Arquette`.
nonisolated public struct HeroCredit: Hashable, Sendable, Identifiable {
    public var label: String
    public var names: String
    public var id: String { label }

    public init(_ label: String, _ names: String) {
        self.label = label
        self.names = names
    }
}

/// Bottom-left hero block (label pill, title/logo, metadata, description + PLUS, tech line +
/// badges, buttons) and the trailing `Avec … / Réalisation …` credits, laid out like the
/// Apple TV detail and home heroes. Place it over a `HeroBackdrop`.
public struct HeroContent<Buttons: View>: View {
    private let label: String?
    private let title: String
    private let logoURL: URL?
    private let metadata: [String]
    private let metadataGlyph: Image?
    private let rating: String?
    private let description: String?
    private let descriptionEmphasis: String?
    private let descriptionLineLimit: Int
    private let techItems: [String]
    private let badges: [BadgeSpec]
    private let credits: [HeroCredit]
    private let bottomPadding: CGFloat
    private let buttons: Buttons

    public init(
        label: String? = nil,
        title: String,
        logoURL: URL? = nil,
        metadata: [String] = [],
        metadataGlyph: Image? = nil,
        rating: String? = nil,
        description: String? = nil,
        descriptionEmphasis: String? = nil,
        descriptionLineLimit: Int = 2,
        techItems: [String] = [],
        badges: [BadgeSpec] = [],
        credits: [HeroCredit] = [],
        bottomPadding: CGFloat = PrismMetrics.heroBottomPadding,
        @ViewBuilder buttons: () -> Buttons
    ) {
        self.descriptionLineLimit = descriptionLineLimit
        self.label = label
        self.title = title
        self.logoURL = logoURL
        self.metadata = metadata
        self.metadataGlyph = metadataGlyph
        self.rating = rating
        self.description = description
        self.descriptionEmphasis = descriptionEmphasis
        self.techItems = techItems
        self.badges = badges
        self.credits = credits
        self.bottomPadding = bottomPadding
        self.buttons = buttons()
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 40) {
            leadingBlock
            Spacer(minLength: 0)
            if !credits.isEmpty {
                creditsBlock
            }
        }
        .padding(.leading, PrismMetrics.contentMargin)
        .padding(.trailing, PrismMetrics.contentMargin + 24)
        .padding(.bottom, bottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .environment(\.colorScheme, .dark)
    }

    private var leadingBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let label {
                LabelPill(label)
                    .padding(.bottom, 10)
            }
            TitleLogo(url: logoURL, fallbackTitle: title)
                .padding(.bottom, 10)
            if !metadata.isEmpty || rating != nil {
                MetadataLine(items: metadata, leadingGlyph: metadataGlyph) {
                    if let rating { AgeRatingBadge(rating) }
                }
                .foregroundStyle(.white.opacity(0.86))
                .padding(.bottom, 9)
            }
            if let description, !description.isEmpty {
                ExpandableText(description, emphasis: descriptionEmphasis, lineLimit: descriptionLineLimit, popoverTitle: title)
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: PrismMetrics.heroTextMaxWidth, alignment: .leading)
                    .padding(.bottom, 10)
            }
            if !techItems.isEmpty || !badges.isEmpty {
                TechLine(items: techItems, badges: badges)
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.bottom, 4)
            }
            HStack(spacing: PrismMetrics.heroButtonSpacing) {
                buttons
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    private var creditsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(credits) { credit in
                Text("\(Text(credit.label).foregroundStyle(.white.opacity(0.55))) \(Text(credit.names).foregroundStyle(.white.opacity(0.92)))")
                    .font(PrismFont.heroCredits)
                    .lineSpacing(PrismFont.heroLineSpacing + 1)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 200, alignment: .leading)
        .padding(.bottom, 4)
        .accessibilityElement(children: .combine)
    }
}

extension HeroContent where Buttons == EmptyView {
    public init(
        label: String? = nil, title: String, logoURL: URL? = nil, metadata: [String] = [], metadataGlyph: Image? = nil,
        rating: String? = nil, description: String? = nil, descriptionEmphasis: String? = nil, descriptionLineLimit: Int = 2,
        techItems: [String] = [], badges: [BadgeSpec] = [], credits: [HeroCredit] = [], bottomPadding: CGFloat = PrismMetrics.heroBottomPadding
    ) {
        self.init(
            label: label, title: title, logoURL: logoURL, metadata: metadata, metadataGlyph: metadataGlyph, rating: rating,
            description: description, descriptionEmphasis: descriptionEmphasis, descriptionLineLimit: descriptionLineLimit,
            techItems: techItems, badges: badges,
            credits: credits, bottomPadding: bottomPadding
        ) { EmptyView() }
    }
}

#Preview("HeroContent") {
    ZStack {
        HeroBackdrop(imageURL: nil, seed: "Severance")
        HeroContent(
            label: "Nouveau",
            title: "Severance",
            metadata: ["Série TV", "Thriller", "Mystère"],
            metadataGlyph: Image(systemName: "play.tv.fill"),
            rating: "16+",
            description: "Mark est promu à la tête d'une équipe d'employés dont les souvenirs ont été chirurgicalement divisés.",
            descriptionEmphasis: "S1, É1 · Bonne nouvelle sur l'enfer :",
            techItems: ["2022", "57 min"],
            badges: [.init("4K", style: .filled), .init("CC", style: .outlined), .init("SDH", style: .outlined), .init("AD", style: .outlined)],
            credits: [HeroCredit("Avec", "Adam Scott, Britt Lower et Patricia Arquette"), HeroCredit("Réalisation", "Ben Stiller")]
        ) {
            PrimaryCapsuleButton("Lecture", systemImage: "play.fill") {}
            WatchlistButton(isAdded: false) {}
            GlassCapsuleButton(title: "Source A · 4K", tint: PrismTint.purple.color) {}
        }
    }
    .frame(width: 1000, height: 560)
}
