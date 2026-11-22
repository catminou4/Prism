import SwiftUI

/// `À propos` panel: title 17 bold, caps genres 10 semibold secondary, description.
public struct AboutCard: View {
    private let title: String
    private let subtitleCaps: String?
    private let text: String
    private let width: CGFloat?

    public init(title: String, subtitle: String? = nil, text: String, width: CGFloat? = 450) {
        self.title = title
        subtitleCaps = subtitle?.uppercased()
        self.text = text
        self.width = width
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(PrismFont.aboutTitle)
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let subtitleCaps, !subtitleCaps.isEmpty {
                Text(subtitleCaps)
                    .font(PrismFont.aboutGenres)
                    .tracking(0.2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 3)
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .frame(width: width, alignment: .leading)
        .background(PrismColors.panelFill, in: .rect(cornerRadius: PrismMetrics.panelRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

#Preview("AboutCard") {
    AboutCard(
        title: "Severance",
        subtitle: "Thriller, Mystery, Drama",
        text: "Mark dirige une équipe d'employés dont les souvenirs ont été chirurgicalement séparés entre leur travail et leur vie privée."
    )
    .padding(40)
}
