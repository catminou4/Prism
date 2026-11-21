import SwiftUI

/// "Comment regarder ?" tile: 56 pt source monogram tile, name 15 semibold, detail
/// (`4K · VF · MKV`) secondary, checkmark when selected.
public struct SourceCard: View {
    private let name: String
    private let detail: String?
    private let tint: PrismTint
    private let isSelected: Bool
    private let logoURL: URL?
    private let width: CGFloat
    private let action: (() -> Void)?

    public init(name: String, detail: String? = nil, tint: PrismTint, isSelected: Bool = false, logoURL: URL? = nil, width: CGFloat = 292, action: (() -> Void)? = nil) {
        self.name = name
        self.detail = detail
        self.tint = tint
        self.isSelected = isSelected
        self.logoURL = logoURL
        self.width = width
        self.action = action
    }

    public var body: some View {
        CardContainer(accessibilityLabel: Text([name, detail].compactMap { $0 }.joined(separator: ", ")), action: action, hoverScale: 1.02, menu: EmptyView()) { _ in
            HStack(spacing: 14) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(PrismFont.sourceName)
                        .foregroundStyle(.primary)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 76)
            .background(PrismColors.panelFill, in: .rect(cornerRadius: PrismMetrics.sourceCardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PrismMetrics.sourceCardRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: isSelected ? 2 : 0)
            }
            .animation(PrismMotion.standard, value: isSelected)
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                if let logoURL {
                    RemoteImage(url: logoURL, size: CGSize(width: 40, height: 40), contentMode: .fit, placeholderSeed: name, showsPlaceholder: false)
                } else {
                    Text(Monogram.initials(from: name))
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 56, height: 56)
    }
}

#Preview("SourceCard") {
    VStack(alignment: .leading, spacing: 12) {
        SourceCard(name: "Source A", detail: "4K · VF · MKV", tint: .purple, isSelected: true)
        SourceCard(name: "IPTV Premium", detail: "HD · VOSTFR · MP4", tint: .orange)
    }
    .padding(40)
}
