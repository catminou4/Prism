import SwiftUI

/// Full-bleed hero artwork with a slow Ken Burns, the Apple TV left/bottom gradients, and a
/// premium poster-only fallback (blurred extended poster + sharp poster on the trailing side).
public struct HeroBackdrop: View {
    private let imageURL: URL?
    private let seed: String
    private let fallbackPosterURL: URL?
    private let fadeInto: Color?
    private let leadingScrim: Double
    private let extendsUnderSidebar: Bool
    private let animates: Bool
    private let artSize: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotRendering) private var snapshot
    @State private var kenBurns = false

    /// - Parameters:
    ///   - fadeInto: When set, the bottom fades into this colour (e.g. `PrismColors.pageBackground`).
    ///     `nil` keeps Apple's hard edge with a legibility gradient.
    ///   - extendsUnderSidebar: Applies `backgroundExtensionEffect()` so the artwork continues
    ///     (mirrored + blurred) under the Liquid Glass sidebar.
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
        self.imageURL = imageURL
        self.seed = seed
        self.fallbackPosterURL = fallbackPosterURL
        self.fadeInto = fadeInto
        self.leadingScrim = leadingScrim
        self.extendsUnderSidebar = extendsUnderSidebar
        self.animates = animates
        self.artSize = artSize
    }

    public var body: some View {
        ZStack {
            Color.black
            artwork
                .modifier(BackgroundExtension(enabled: extendsUnderSidebar))
            scrims
        }
        .clipped()
        .accessibilityHidden(true)
        .onChange(of: animates && !reduceMotion && !snapshot, initial: true) { _, shouldAnimate in
            kenBurns = shouldAnimate
        }
    }

    @ViewBuilder private var artwork: some View {
        if imageURL != nil || fallbackPosterURL == nil {
            RemoteImage(url: imageURL, size: artSize, placeholderSeed: seed, placeholderStyle: .none)
                .scaleEffect(kenBurns ? 1.06 : 1, anchor: .center)
                .animation(kenBurns ? .easeInOut(duration: PrismMotion.kenBurnsDuration).repeatForever(autoreverses: true) : nil, value: kenBurns)
        } else {
            PosterHeroArtwork(posterURL: fallbackPosterURL, seed: seed, kenBurns: kenBurns)
        }
    }

    private var scrims: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: .black.opacity(leadingScrim), location: 0),
                    .init(color: .black.opacity(leadingScrim * 0.45), location: 0.32),
                    .init(color: .black.opacity(0), location: 0.6),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            if let fadeInto {
                LinearGradient(
                    stops: [.init(color: fadeInto.opacity(0), location: 0.55), .init(color: fadeInto.opacity(0.85), location: 0.9), .init(color: fadeInto, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            } else {
                LinearGradient(
                    stops: [.init(color: .black.opacity(0), location: 0.5), .init(color: .black.opacity(0.55), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
            }
        }
        .allowsHitTesting(false)
    }
}

private struct BackgroundExtension: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.backgroundExtensionEffect() } else { content }
    }
}

/// Poster-only hero: the poster blurred and stretched as backdrop, the sharp poster on the right.
private struct PosterHeroArtwork: View {
    let posterURL: URL?
    let seed: String
    let kenBurns: Bool

    var body: some View {
        ZStack {
            RemoteImage(url: posterURL, placeholderSeed: seed, placeholderStyle: .none, blurRadius: 36)
                .scaleEffect(1.15)
                .overlay(Color.black.opacity(0.35))
                .saturation(1.15)
            GeometryReader { proxy in
                let height = min(proxy.size.height * 0.74, 520)
                let width = height * PrismMetrics.posterAspectRatio
                RemoteImage(url: posterURL, size: CGSize(width: width, height: height), placeholderSeed: seed, placeholderTitle: nil)
                    .clipShape(.rect(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                    .scaleEffect(kenBurns ? 1.02 : 1)
                    .animation(kenBurns ? .easeInOut(duration: PrismMotion.kenBurnsDuration).repeatForever(autoreverses: true) : .default, value: kenBurns)
                    .position(x: proxy.size.width - max(proxy.size.width * 0.1, 60) - width / 2, y: proxy.size.height * 0.46)
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
