import SwiftUI

/// Low-resolution artwork behind the scroll view, visible during the top rubber-band bounce.
public struct HeroOverscrollBackground: View {
    private let backdrops: [URL]
    private let posters: [URL]
    private let seed: String
    @State private var failedURLs: Set<URL> = []

    public init(backdropURLs: [URL], fallbackPosterURLs: [URL] = [], seed: String) {
        self.backdrops = backdropURLs
        self.posters = fallbackPosterURLs
        self.seed = seed
    }

    public var body: some View {
        ZStack {
            PlaceholderArtwork(seed: seed, style: .none)
            if let url = backdrops.first(where: { !failedURLs.contains($0) }) {
                blurredArtwork(url, fitting: .landscapeFill)
            } else if let url = posters.first(where: { !failedURLs.contains($0) }) {
                blurredArtwork(url, fitting: .portraitFit)
            }
            LinearGradient(
                colors: [.black.opacity(0.5), .clear],
                startPoint: .leading, endPoint: .trailing
            )
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func blurredArtwork(_ url: URL, fitting: ImagePipeline.Fitting) -> some View {
        RemoteImage(
            url: url, alignment: .top, fitting: fitting, placeholderSeed: seed,
            blurRadius: 32, showsPlaceholder: false,
            onLoadFailure: { failedURLs.insert(url) }
        )
        .id(url)
    }
}
