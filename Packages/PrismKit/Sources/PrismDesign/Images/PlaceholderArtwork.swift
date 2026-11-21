import CoreGraphics
import SwiftUI

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

    private let seed: String
    private let title: String?
    private let style: TitleStyle

    public init(seed: String, title: String? = nil, style: TitleStyle = .title) {
        self.seed = seed
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.style = title == nil ? .none : style
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
        let palette = Palette(seed: seed)
        return ZStack {
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

        init(seed: String) {
            var rng = StableHash.Generator(seed: seed)
            top = Color(white: 0.12 + rng.unit() * 0.19)
            bottom = Color(white: 0.045 + rng.unit() * 0.045)
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
