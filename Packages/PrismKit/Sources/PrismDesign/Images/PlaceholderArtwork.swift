import CoreGraphics
import SwiftUI

/// Deterministic, Apple-like dark artwork used while an image loads or when none exists.
///
/// The palette, gradient angle and glow position derive from a stable hash of `seed`, so the
/// same title always gets the same placeholder (across launches and machines).
public struct PlaceholderArtwork: View {
    public enum TitleStyle: Sendable {
        /// Centred title in bold type (posters, tiles).
        case title
        /// Large initials (people, channels, sources).
        case monogram
        /// Gradient only.
        case none
    }

    private let palette: Palette
    private let title: String?
    private let style: TitleStyle

    public init(seed: String, title: String? = nil, style: TitleStyle = .title) {
        palette = Palette(seed: seed)
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.style = title == nil ? .none : style
    }

    public var body: some View {
        if style == .monogram {
            monogramBody
        } else {
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
            RadialGradient(colors: [palette.glow.opacity(0.42), palette.glow.opacity(0)], center: palette.glowCenter, startRadius: 0, endRadius: 240)
            RadialGradient(colors: [.clear, .black.opacity(0.38)], center: .center, startRadius: 40, endRadius: 320)
            NoiseTexture.image
                .resizable(resizingMode: .tile)
                .opacity(0.06)
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
            case .none:
                EmptyView()
            }
        }
    }

    /// Curated dark palettes (top, bottom, glow).
    struct Palette {
        let top: Color
        let bottom: Color
        let glow: Color
        let start: UnitPoint
        let end: UnitPoint
        let glowCenter: UnitPoint

        static let swatches: [(Double, Double, Double, Double, Double, Double, Double, Double, Double)] = [
            (0.15, 0.19, 0.32, 0.04, 0.05, 0.10, 0.36, 0.46, 0.78), // indigo night
            (0.27, 0.13, 0.25, 0.07, 0.03, 0.08, 0.66, 0.32, 0.54), // plum
            (0.31, 0.10, 0.12, 0.08, 0.02, 0.04, 0.78, 0.34, 0.28), // burgundy
            (0.08, 0.22, 0.25, 0.02, 0.06, 0.08, 0.24, 0.60, 0.62), // deep teal
            (0.12, 0.21, 0.15, 0.03, 0.06, 0.04, 0.40, 0.60, 0.40), // forest
            (0.21, 0.23, 0.28, 0.05, 0.06, 0.08, 0.55, 0.60, 0.70), // slate
            (0.31, 0.20, 0.10, 0.08, 0.05, 0.03, 0.80, 0.56, 0.30), // amber
            (0.19, 0.14, 0.33, 0.05, 0.03, 0.10, 0.52, 0.42, 0.84), // violet
            (0.09, 0.16, 0.28, 0.02, 0.04, 0.08, 0.30, 0.52, 0.80), // ocean
            (0.30, 0.15, 0.18, 0.07, 0.04, 0.06, 0.78, 0.46, 0.52), // rose
            (0.24, 0.23, 0.14, 0.06, 0.06, 0.03, 0.70, 0.66, 0.40), // olive gold
            (0.17, 0.18, 0.20, 0.04, 0.04, 0.05, 0.50, 0.52, 0.56), // graphite
        ]

        init(seed: String) {
            var rng = StableHash.Generator(seed: seed)
            let swatch = Self.swatches[Int(rng.next() % UInt64(Self.swatches.count))]
            top = Color(.sRGB, red: swatch.0, green: swatch.1, blue: swatch.2)
            bottom = Color(.sRGB, red: swatch.3, green: swatch.4, blue: swatch.5)
            glow = Color(.sRGB, red: swatch.6, green: swatch.7, blue: swatch.8)
            let angle = rng.unit() * .pi * 0.5 - .pi * 0.25 // −45°…45° around vertical
            start = UnitPoint(x: 0.5 - sin(angle) * 0.5, y: 0)
            end = UnitPoint(x: 0.5 + sin(angle) * 0.5, y: 1)
            glowCenter = UnitPoint(x: 0.15 + rng.unit() * 0.7, y: 0.05 + rng.unit() * 0.35)
        }
    }
}

/// A tiny tiling grain texture generated once.
enum NoiseTexture {
    static let image: Image = {
        let side = 64
        var rng = StableHash.Generator(seed: 0x5EED)
        var bytes = [UInt8](repeating: 0, count: side * side)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: rng.next() >> 56) }
        let data = Data(bytes) as CFData
        guard let provider = CGDataProvider(data: data),
              let cgImage = CGImage(
                  width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { return Image(systemName: "circle.fill") }
        return Image(decorative: cgImage, scale: 2)
    }()
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
