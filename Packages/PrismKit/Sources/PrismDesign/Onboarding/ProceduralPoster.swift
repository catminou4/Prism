import SwiftUI

/// A fake but convincing 2:3 "poster": seeded MeshGradient, a light bloom and title
/// typography in one of several styles. Used by `PosterWall` when no artwork is given.
public struct ProceduralPoster: View {
    private let seed: String
    private let title: String
    private let design: Design

    struct Design {
        let colors: [Color]
        let points: [SIMD2<Float>]
        let bloom: UnitPoint
        let bloomColor: Color
        let typography: Int
        let showsMark: Bool

        init(seed: String) {
            var rng = StableHash.Generator(seed: seed)
            let palettes: [[(Double, Double, Double)]] = [
                [(0.95, 0.45, 0.20), (0.55, 0.10, 0.20), (0.10, 0.05, 0.12)], // ember
                [(0.20, 0.55, 0.95), (0.10, 0.20, 0.55), (0.02, 0.04, 0.12)], // ocean
                [(0.98, 0.82, 0.30), (0.85, 0.45, 0.15), (0.25, 0.10, 0.05)], // sunset gold
                [(0.55, 0.85, 0.75), (0.15, 0.45, 0.45), (0.02, 0.10, 0.12)], // teal
                [(0.85, 0.40, 0.75), (0.40, 0.15, 0.55), (0.08, 0.03, 0.15)], // neon violet
                [(0.90, 0.90, 0.85), (0.55, 0.58, 0.62), (0.12, 0.13, 0.16)], // silver
                [(0.95, 0.25, 0.30), (0.35, 0.05, 0.10), (0.05, 0.02, 0.04)], // crimson
                [(0.45, 0.75, 0.35), (0.15, 0.35, 0.18), (0.03, 0.08, 0.05)], // jungle
                [(0.35, 0.40, 0.95), (0.70, 0.30, 0.65), (0.08, 0.05, 0.20)], // dusk
                [(0.98, 0.60, 0.55), (0.60, 0.35, 0.55), (0.15, 0.10, 0.20)], // peach
            ]
            let palette = palettes[Int(rng.next() % UInt64(palettes.count))]
            func color(_ c: (Double, Double, Double), _ jitter: Double) -> Color {
                Color(.sRGB, red: min(1, c.0 * jitter), green: min(1, c.1 * jitter), blue: min(1, c.2 * jitter))
            }
            var colors: [Color] = []
            for row in 0..<3 {
                for _ in 0..<3 {
                    let base = palette[min(2, row + Int(rng.next() % 2) * (row == 0 ? 1 : 0))]
                    colors.append(color(base, 0.8 + rng.unit() * 0.35))
                }
            }
            self.colors = colors
            let cx = Float(0.35 + rng.unit() * 0.3), cy = Float(0.35 + rng.unit() * 0.3)
            points = [
                [0, 0], [0.5, 0], [1, 0],
                [0, 0.5], [cx, cy], [1, 0.5],
                [0, 1], [0.5, 1], [1, 1],
            ]
            bloom = UnitPoint(x: 0.25 + rng.unit() * 0.5, y: 0.2 + rng.unit() * 0.35)
            bloomColor = color(palette[0], 1.1)
            typography = Int(rng.next() % 4)
            showsMark = rng.unit() > 0.4
        }
    }

    public init(seed: String, title: String) {
        self.seed = seed
        self.title = title
        design = Design(seed: seed)
    }

    public var body: some View {
        ZStack {
            MeshGradient(width: 3, height: 3, points: design.points, colors: design.colors)
            RadialGradient(colors: [design.bloomColor.opacity(0.7), .clear], center: design.bloom, startRadius: 0, endRadius: 120)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom)
            typography
            if design.showsMark {
                PrismLogoMark(size: 12, style: .monochrome(.white.opacity(0.85)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var typography: some View {
        switch design.typography {
        case 0:
            Text(title.uppercased())
                .font(.system(size: 26, weight: .black, design: .default).width(.condensed))
                .tracking(0.5)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 16)
        case 1:
            Text(title)
                .font(.system(size: 24, weight: .semibold, design: .serif))
                .italic()
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 20)
        case 2:
            Text(title.uppercased())
                .font(.system(size: 15, weight: .medium))
                .tracking(4)
                .foregroundStyle(.white.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 10)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 22)
        default:
            Text(title)
                .font(.system(size: 28, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 14)
        }
    }
}

#Preview("ProceduralPoster") {
    HStack(spacing: 14) {
        ForEach(["Nocturne", "Les Échos", "Polaris", "Le Dernier Été"], id: \.self) { title in
            ProceduralPoster(seed: title, title: title)
                .frame(width: 140, height: 210)
                .clipShape(.rect(cornerRadius: PrismMetrics.posterRadius))
        }
    }
    .padding(30)
    .background(.black)
}
