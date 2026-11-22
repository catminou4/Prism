import SwiftUI

/// Cinema-format hero artwork with legibility scrims and a portrait-only fallback.
public struct HeroBackdrop: View {
    private let backdropURLs: [URL]
    private let seed: String
    private let posterURLs: [URL]
    private let fadeInto: Color?
    private let leadingScrim: Double
    private let extendsUnderSidebar: Bool
    private let artSize: CGSize?
    @State private var failedBackdrops: Set<URL> = []
    @State private var failedPosters: Set<URL> = []

    /// - Parameters:
    ///   - fadeInto: When set, the bottom fades into this colour (e.g. `PrismColors.pageBackground`).
    ///     `nil` keeps a dark legibility gradient.
    ///   - extendsUnderSidebar: Applies `backgroundExtensionEffect()` so the artwork continues
    ///     (mirrored + blurred) under the Liquid Glass sidebar.
    ///   - animates: Kept for source compatibility. The artwork stays still: a perpetual zoom kept the
    ///     main thread and the sidebar's extension blur busy on every frame for a barely visible effect.
    public init(
        imageURL: URL?,
        seed: String,
        fallbackPosterURL: URL? = nil,
        fadeInto: Color? = nil,
        leadingScrim: Double = 0.75,
        extendsUnderSidebar: Bool = false,
        animates: Bool = true,
        artSize: CGSize? = nil
    ) {
        self.init(
            backdropURLs: [imageURL].compactMap { $0 }, seed: seed,
            fallbackPosterURLs: [fallbackPosterURL].compactMap { $0 }, fadeInto: fadeInto,
            leadingScrim: leadingScrim, extendsUnderSidebar: extendsUnderSidebar, animates: animates, artSize: artSize
        )
    }

    /// Tries the supplied artwork in priority order. Landscape and portrait roles are checked
    /// against the actual image, including its orientation, before allocating a thumbnail.
    public init(
        backdropURLs: [URL],
        seed: String,
        fallbackPosterURLs: [URL] = [],
        fadeInto: Color? = nil,
        leadingScrim: Double = 0.72,
        extendsUnderSidebar: Bool = false,
        animates: Bool = false,
        artSize: CGSize? = nil
    ) {
        self.backdropURLs = Self.unique(backdropURLs)
        self.seed = seed
        self.posterURLs = Self.unique(fallbackPosterURLs.isEmpty ? Array(backdropURLs.prefix(1)) : fallbackPosterURLs)
        self.fadeInto = fadeInto
        self.leadingScrim = leadingScrim
        self.extendsUnderSidebar = extendsUnderSidebar
        self.artSize = artSize
    }

    public var body: some View {
        ZStack {
            PlaceholderArtwork(seed: seed, style: .none)
            artwork
            scrims
        }
        .clipped()
        // Extend the completed, clipped backdrop rather than clipping the extension itself.
        .backgroundExtensionEffect(isEnabled: extendsUnderSidebar)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var artwork: some View {
        if let url = backdropURLs.first(where: { !failedBackdrops.contains($0) }) {
            RemoteImage(
                url: url, size: artSize, alignment: .top, fitting: .landscapeFill,
                placeholderSeed: seed, showsPlaceholder: false, progressive: true,
                onLoadFailure: { failedBackdrops.insert(url) }
            )
            .id(url)
        } else if let url = posterURLs.first(where: { !failedPosters.contains($0) }) {
            PosterHeroArtwork(posterURL: url, seed: seed, onLoadFailure: { failedPosters.insert(url) })
                .id(url)
        }
    }

    private var scrims: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(leadingScrim), location: 0),
                    .init(color: .black.opacity(leadingScrim * 0.42), location: 0.33),
                    .init(color: .clear, location: 0.64),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            if let fadeInto {
                LinearGradient(
                    stops: [.init(color: fadeInto.opacity(0), location: 0.55), .init(color: fadeInto.opacity(0.85), location: 0.9), .init(color: fadeInto, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: .black.opacity(0.30), location: 0.76),
                    .init(color: .black.opacity(0.70), location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen: Set<URL> = []
        var artwork: [URL] = []
        for url in urls where seen.insert(url).inserted {
            artwork.append(url)
            if artwork.count == 4 { break }
        }
        return artwork
    }
}

/// A portrait stays fully legible. Its colours continue into the stage behind the text.
private struct PosterHeroArtwork: View {
    let posterURL: URL
    let seed: String
    let onLoadFailure: () -> Void

    var body: some View {
        ZStack {
            RemoteImage(
                url: posterURL, fitting: .portraitFit, placeholderSeed: seed,
                blurRadius: 34, showsPlaceholder: false
            )
            .overlay(Color.black.opacity(0.43))
            GeometryReader { proxy in
                let height = min(proxy.size.height * 0.78, proxy.size.width * 0.52, 510)
                let width = height * PrismMetrics.posterAspectRatio
                let clip = RoundedRectangle(cornerRadius: PrismMetrics.posterRadius)
                RemoteImage(
                    url: posterURL, size: CGSize(width: width, height: height), contentMode: .fit,
                    fitting: .portraitFit, placeholderSeed: seed, showsPlaceholder: false, onLoadFailure: onLoadFailure
                )
                .clipShape(clip)
                .overlay { clip.strokeBorder(.white.opacity(0.10), lineWidth: 1) }
                .shadow(color: .black.opacity(0.45), radius: 20, y: 12)
                .position(
                    x: proxy.size.width - max(proxy.size.width * 0.11, 32) - width / 2,
                    y: proxy.size.height * 0.48
                )
            }
        }
    }
}

#Preview("HeroBackdrop") {
    VStack(spacing: 0) {
        HeroBackdrop(imageURL: nil, seed: "Severance").frame(height: 360)
        HeroBackdrop(imageURL: nil, seed: "Silo", fallbackPosterURL: URL(string: "https://example.com/p.jpg")).frame(height: 360)
    }
    .frame(width: 1000)
}
