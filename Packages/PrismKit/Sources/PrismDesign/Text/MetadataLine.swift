import SwiftUI

/// `[glyph] Série TV · Thriller · Mystery [16+]` — items joined with ` · `.
public struct MetadataLine<Trailing: View>: View {
    private let items: [String]
    private let leadingGlyph: Image?
    private let font: Font
    private let trailing: Trailing

    public init(items: [String], leadingGlyph: Image? = nil, font: Font = PrismFont.heroMeta, @ViewBuilder trailingBadge: () -> Trailing) {
        self.items = items.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        self.leadingGlyph = leadingGlyph
        self.font = font
        self.trailing = trailingBadge()
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let leadingGlyph {
                leadingGlyph
                    .resizable()
                    .scaledToFit()
                    .frame(width: 14, height: 14)
            }
            Text(items.joined(separator: " · "))
                .font(font)
                .lineLimit(1)
                .truncationMode(.tail)
            trailing
        }
        .accessibilityElement(children: .combine)
    }
}

extension MetadataLine where Trailing == EmptyView {
    public init(items: [String], leadingGlyph: Image? = nil, font: Font = PrismFont.heroMeta) {
        self.init(items: items, leadingGlyph: leadingGlyph, font: font) { EmptyView() }
    }
}

/// `2022 · 57 min` followed by badges — the hero tech line.
public struct TechLine: View {
    private let items: [String]
    private let badges: [BadgeSpec]

    public init(items: [String], badges: [BadgeSpec] = []) {
        self.items = items.filter { !$0.isEmpty }
        self.badges = badges
    }

    public var body: some View {
        HStack(spacing: 8) {
            if !items.isEmpty {
                Text(items.joined(separator: " · "))
                    .font(PrismFont.techLine)
                    .lineLimit(1)
                    .fixedSize()
            }
            BadgeRow(badges)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("MetadataLine") {
    VStack(alignment: .leading, spacing: 10) {
        MetadataLine(items: ["Série TV", "Thriller", "Mystery"], leadingGlyph: Image(systemName: "play.tv.fill")) {
            AgeRatingBadge("16+")
        }
        TechLine(items: ["2022", "57 min"], badges: [.init("4K", style: .filled), .init("CC", style: .outlined), .init("AD", style: .outlined)])
    }
    .foregroundStyle(.white.opacity(0.85))
    .padding(30)
    .background(.black)
}
