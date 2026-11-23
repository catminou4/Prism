import CoreGraphics
import SwiftUI

/// Title logo (TMDB logo artwork) constrained to 420×120, or the hero title text.
/// The text shows until the logo decodes, then cross-fades to it.
public struct TitleLogo: View {
    private let url: URL?
    private let fallbackTitle: String
    private let maxSize: CGSize
    @State private var logo: CGImage?
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(url: URL?, fallbackTitle: String, maxSize: CGSize = CGSize(width: PrismMetrics.titleLogoMaxWidth, height: PrismMetrics.titleLogoMaxHeight)) {
        self.url = url
        self.fallbackTitle = fallbackTitle
        self.maxSize = maxSize
    }

    public var body: some View {
        Group {
            if let logo {
                Image(decorative: logo, scale: displayScale)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: maxSize.width, maxHeight: maxSize.height, alignment: .bottomLeading)
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                    .transition(.opacity)
                    .accessibilityLabel(Text(fallbackTitle))
            } else {
                HeroTitleText(fallbackTitle)
                    .transition(.opacity)
            }
        }
        .accessibilityAddTraits(.isHeader)
        .onChange(of: url) { _, _ in logo = nil }
        .task(id: url) {
            guard let url else { logo = nil; return }
            let pixels = CGSize(width: maxSize.width * displayScale, height: maxSize.height * displayScale)
            var image = ImagePipeline.shared.cachedImage(for: url, pixelSize: pixels, fitting: .fit)
            if image == nil {
                image = await ImagePipeline.shared.image(for: url, pixelSize: pixels, fitting: .fit)
            }
            if let image, !Task.isCancelled {
                withAnimation(PrismMotion.respecting(reduceMotion, PrismMotion.imageFade)) { logo = image }
            }
        }
    }
}

/// Hero title text when no logo exists: bold, tight, max 2 lines, scales down to fit.
public struct HeroTitleText: View {
    private let title: String
    private let font: Font

    public init(_ title: String, font: Font = PrismFont.heroTitle) {
        self.title = title
        self.font = font
    }

    public var body: some View {
        Text(title)
            .font(font)
            .tracking(PrismFont.heroTitleTracking)
            .foregroundStyle(.white)
            .lineLimit(2)
            .minimumScaleFactor(0.55)
            .lineSpacing(-6)
            .shadow(color: .black.opacity(0.2), radius: 10, y: 2)
            .frame(maxWidth: PrismMetrics.titleLogoMaxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview("TitleLogo") {
    VStack(alignment: .leading, spacing: 20) {
        TitleLogo(url: nil, fallbackTitle: "Severance")
        TitleLogo(url: nil, fallbackTitle: "Le Seigneur des anneaux : Les Anneaux de pouvoir")
    }
    .padding(40)
    .frame(width: 600, alignment: .leading)
    .background(.black)
}
