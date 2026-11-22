import SwiftUI
import Synchronization

/// Deterministic neutral artwork used while an image loads or when none is available.
///
/// Tonal differences help distinguish titles without competing with poster art.
public struct PlaceholderArtwork: View {
    public enum TitleStyle: Sendable {
        /// Centred title in bold type (posters, tiles).
        case title
        /// Large initials (people, channels, sources).
        case monogram
        /// Quiet initials on a caller-provided surface while a channel logo loads.
        case channelLogo
        /// Gradient only.
        case none
    }

    private let title: String?
    private let style: TitleStyle
    private let palette: Palette

    public init(seed: String, title: String? = nil, style: TitleStyle = .title) {
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.style = title == nil ? .none : style
        // Computed once per view instead of on every `body` evaluation (the palette only
        // depends on the seed, which never changes for a given placeholder).
        palette = Palette(seed: seed)
    }

    public var body: some View {
        switch style {
        case .monogram:
            monogramBody
        case .channelLogo:
            label.accessibilityHidden(true)
        case .title, .none:
            artworkBody
        }
    }

    /// Contacts-style neutral portrait placeholder.
    private var monogramBody: some View {
        LinearGradient(
            colors: [Color(.sRGB, red: 0.64, green: 0.66, blue: 0.70), Color(.sRGB, red: 0.45, green: 0.47, blue: 0.51)],
            startPoint: .top, endPoint: .bottom
        )
        .overlay { label }
        .accessibilityHidden(true)
    }

    private var artworkBody: some View {
        ZStack {
            LinearGradient(colors: [palette.top, palette.bottom], startPoint: palette.start, endPoint: palette.end)
            RadialGradient(colors: [.white.opacity(0.10), .clear], center: palette.glowCenter, startRadius: 0, endRadius: 225)
            label
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var label: some View {
        if let title {
            switch style {
            case .title:
                Text(title)
                    .font(.system(size: 21, weight: .bold))
                    .tracking(-0.3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .minimumScaleFactor(0.5)
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 22)
            case .monogram:
                Text(Monogram.initials(from: title))
                    .font(.system(size: 120, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.05)
                    .padding(22)
            case .channelLogo:
                Text(Monogram.initials(from: title))
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                    .minimumScaleFactor(0.32)
                    .padding(4)
            case .none:
                EmptyView()
            }
        }
    }

    struct Palette {
        let top: Color
        let bottom: Color
        let start: UnitPoint
        let end: UnitPoint
        let glowCenter: UnitPoint

        /// Palettes are tiny and seeds repeat across re-evaluations; memoize so the FNV-1a +
        /// SplitMix64 work happens once per seed instead of once per `body` pass per card.
        private static let memo = Mutex<[String: Palette]>([:])
        private static let memoLimit = 2_048

        init(seed: String) {
            if let hit = Self.memo.withLock({ $0[seed] }) {
                self = hit
                return
            }
            var rng = StableHash.Generator(seed: seed)
            top = Color(white: 0.12 + rng.unit() * 0.19)
            bottom = Color(white: 0.045 + rng.unit() * 0.045)
            let angle = rng.unit() * .pi * 0.5 - .pi * 0.25 // −45°…45° around vertical
            start = UnitPoint(x: 0.5 - sin(angle) * 0.5, y: 0)
            end = UnitPoint(x: 0.5 + sin(angle) * 0.5, y: 1)
            glowCenter = UnitPoint(x: 0.15 + rng.unit() * 0.7, y: 0.05 + rng.unit() * 0.35)
            Self.memo.withLock { memo in
                if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
                memo[seed] = self
            }
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

#Preview("Placeholders") {
    HStack(spacing: 16) {
        ForEach(["Dune", "Severance", "The Bear", "Arcane", "Slow Horses"], id: \.self) { title in
            PlaceholderArtwork(seed: title, title: title)
                .frame(width: 137, height: 205)
                .clipShape(.rect(cornerRadius: 10))
        }
        PlaceholderArtwork(seed: "Adam Scott", title: "Adam Scott", style: .monogram)
            .frame(width: 96, height: 96)
            .clipShape(.circle)
    }
    .padding(40)
}
