import SwiftUI

/// Small technical badge: outlined (`CC`, `SDH`, `AD`, `VOSTFR`, `MULTI`) or filled
/// (`4K`, `HD`, `FHD`, `HDR`). Colours follow the foreground style (white 75 % on the hero).
public struct MediaBadge: View {
    nonisolated public enum Style: Sendable, Hashable {
        case outlined
        case filled
    }

    /// Quality labels rendered filled; everything else outlined.
    nonisolated static let filledLabels: Set<String> = ["4K", "UHD", "HD", "FHD", "HDR", "HDR10", "DV", "8K", "SD"]

    private let displayText: String
    private let accessibilityText: Text
    private let style: Style

    public init(_ text: String, style: Style = .outlined) {
        displayText = text.uppercased()
        accessibilityText = Text(Self.spokenLabel(text))
        self.style = style
    }

    /// Whether `text` is a picture-quality label (`4K`, `HDR`…) rendered filled.
    public nonisolated static func isQualityLabel(_ text: String) -> Bool {
        filledLabels.contains(text.uppercased())
    }

    /// Picks the Apple convention for well-known labels (quality → filled, others → outlined).
    public init(automatic text: String) {
        self.init(text, style: Self.filledLabels.contains(text.uppercased()) ? .filled : .outlined)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: PrismMetrics.badgeRadius, style: .continuous)
        Text(displayText)
            .font(PrismFont.badge)
            .tracking(0.2)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, PrismMetrics.badgeHorizontalPadding)
            .frame(height: PrismMetrics.badgeHeight)
            .frame(minWidth: PrismMetrics.badgeHeight + 4)
            .foregroundStyle(style == .filled ? AnyShapeStyle(.black) : AnyShapeStyle(.foreground))
            .background {
                switch style {
                case .filled: shape.fill(.foreground)
                case .outlined: shape.strokeBorder(.foreground, lineWidth: 1)
                }
            }
            .compositingGroup()
            .accessibilityLabel(accessibilityText)
    }

    static func spokenLabel(_ text: String) -> String {
        switch text.uppercased() {
        case "CC": "Sous-titres codés"
        case "SDH": "Sous-titres pour sourds et malentendants"
        case "AD": "Audiodescription"
        case "VOSTFR": "Version originale sous-titrée"
        case "MULTI": "Multilingue"
        default: text
        }
    }
}

/// Description of one badge in a `BadgeRow`.
nonisolated public struct BadgeSpec: Hashable, Sendable, Identifiable {
    public var text: String
    public var style: MediaBadge.Style
    public var id: String { text }

    public init(_ text: String, style: MediaBadge.Style) {
        self.text = text
        self.style = style
    }

    /// Filled for quality labels, outlined otherwise.
    public init(automatic text: String) {
        self.init(text, style: MediaBadge.filledLabels.contains(text.uppercased()) ? .filled : .outlined)
    }
}

/// Horizontal row of badges (tech line).
public struct BadgeRow: View {
    private let badges: [BadgeSpec]
    private let spacing: CGFloat

    public init(_ badges: [BadgeSpec], spacing: CGFloat = 6) {
        self.badges = badges
        self.spacing = spacing
    }

    public var body: some View {
        HStack(spacing: spacing) {
            // Index ids: `BadgeSpec.id` is the text, which providers may repeat.
            ForEach(badges.indices, id: \.self) { index in
                MediaBadge(badges[index].text, style: badges[index].style)
            }
        }
    }
}

#Preview("Badges") {
    VStack(alignment: .leading, spacing: 12) {
        BadgeRow([.init("4K", style: .filled), .init("HDR", style: .filled), .init("CC", style: .outlined), .init("SDH", style: .outlined), .init("AD", style: .outlined)])
        BadgeRow([.init(automatic: "FHD"), .init(automatic: "VOSTFR"), .init(automatic: "MULTI")])
    }
    .foregroundStyle(.white.opacity(0.75))
    .padding(30)
    .background(.black)
}
