import SwiftUI

/// The Prism mark: a rounded play triangle made of three translucent facets that overlap
/// along bright seams, each refracting a faint spectral tint (cyan / violet / magenta–amber).
public struct PrismLogoMark: View {
    public enum Style: Sendable {
        /// White with spectral tints — for dark backgrounds (icon, onboarding, hero).
        case spectral
        /// Deeper spectral tones — for light backgrounds.
        case onLight
        /// Single colour (empty states, menu bar).
        case monochrome(Color)
    }

    private let size: CGFloat
    private let style: Style
    /// 0 = facets scattered, 1 = assembled (animation hook).
    var assembly: Double = 1
    /// Light sweep position (−0.4…1.4, `nil` = none).
    var sweep: Double?
    /// Per-facet assembly (top, left, bottom) — overrides `assembly` when set.
    var facetAssembly: [Double]?

    public init(size: CGFloat = 64, style: Style = .spectral) {
        self.size = size
        self.style = style
    }

    init(size: CGFloat, style: Style, facetAssembly: [Double], sweep: Double?) {
        self.size = size
        self.style = style
        self.facetAssembly = facetAssembly
        self.sweep = sweep
    }

    public var body: some View {
        ZStack {
            ForEach(Array(PrismFacet.Kind.allCases.enumerated()), id: \.offset) { index, kind in
                facet(kind, progress: facetAssembly?[safe: index] ?? assembly)
            }
            seams
            if let sweep {
                sweepBand(sweep)
            }
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .accessibilityElement()
        .accessibilityLabel("Prism")
    }

    // MARK: Facets

    private func facet(_ kind: PrismFacet.Kind, progress: Double) -> some View {
        let p = min(max(progress, 0), 1.2)
        let spread = (1 - p) * size * 0.55
        let direction = kind.outward
        let rotation: Double = switch kind {
        case .top: -38
        case .left: 52
        case .bottom: 30
        }
        return PrismFacet(kind: kind)
            .fill(gradient(for: kind))
            .scaleEffect(1.012) // slight overlap → brighter seams where facets meet
            .mask(PrismTriangle())
            .opacity(facetOpacity(kind) * min(1, p * 2.2))
            .rotationEffect(.degrees(rotation * (1 - p)), anchor: UnitPoint(x: PrismGeometry.centroid.x, y: PrismGeometry.centroid.y))
            .offset(x: direction.dx * spread, y: direction.dy * spread)
            .blendMode(blend)
    }

    private var blend: BlendMode {
        switch style {
        case .spectral: .plusLighter
        case .onLight: .normal
        case .monochrome: .normal
        }
    }

    private func facetOpacity(_ kind: PrismFacet.Kind) -> Double {
        switch style {
        case .spectral: kind == .top ? 0.98 : 0.9
        case .onLight: 0.92
        case .monochrome: kind == .top ? 1 : (kind == .left ? 0.78 : 0.62)
        }
    }

    private func gradient(for kind: PrismFacet.Kind) -> LinearGradient {
        let stops: [Gradient.Stop]
        switch style {
        case .spectral:
            stops = switch kind {
            case .top: [.init(color: Color(.sRGB, red: 1, green: 1, blue: 1), location: 0), .init(color: Color(.sRGB, red: 0.76, green: 0.92, blue: 1.0), location: 1)]
            case .left: [.init(color: Color(.sRGB, red: 0.96, green: 0.95, blue: 1.0), location: 0), .init(color: Color(.sRGB, red: 0.74, green: 0.70, blue: 1.0), location: 1)]
            case .bottom: [
                .init(color: Color(.sRGB, red: 0.98, green: 0.78, blue: 0.90), location: 0),
                .init(color: Color(.sRGB, red: 1.0, green: 0.90, blue: 0.92), location: 0.55),
                .init(color: Color(.sRGB, red: 1.0, green: 0.86, blue: 0.66), location: 1),
            ]
            }
        case .onLight:
            stops = switch kind {
            case .top: [.init(color: Color(.sRGB, red: 0.36, green: 0.70, blue: 0.98), location: 0), .init(color: Color(.sRGB, red: 0.20, green: 0.60, blue: 0.94), location: 1)]
            case .left: [.init(color: Color(.sRGB, red: 0.50, green: 0.44, blue: 0.96), location: 0), .init(color: Color(.sRGB, red: 0.36, green: 0.30, blue: 0.88), location: 1)]
            case .bottom: [.init(color: Color(.sRGB, red: 0.90, green: 0.34, blue: 0.66), location: 0), .init(color: Color(.sRGB, red: 0.98, green: 0.60, blue: 0.36), location: 1)]
            }
        case .monochrome(let color):
            stops = [.init(color: color, location: 0), .init(color: color, location: 1)]
        }
        // Light radiates from the centroid towards each facet's outer edge.
        let g = UnitPoint(x: PrismGeometry.centroid.x, y: PrismGeometry.centroid.y)
        let end: UnitPoint = switch kind {
        case .top: UnitPoint(x: 0.56, y: 0.2)
        case .left: UnitPoint(x: 0.2, y: 0.5)
        case .bottom: UnitPoint(x: 0.9, y: 0.62)
        }
        let start: UnitPoint = kind == .bottom ? UnitPoint(x: 0.25, y: 0.75) : g
        return LinearGradient(stops: stops, startPoint: start, endPoint: end)
    }

    // MARK: Seams & light

    /// Bright refraction lines from the centroid to each vertex.
    private var seams: some View {
        Canvas { context, canvasSize in
            let rect = CGRect(origin: .zero, size: canvasSize)
            let g = PrismGeometry.point(PrismGeometry.centroid, in: rect)
            var path = Path()
            for vertex in [PrismGeometry.a, PrismGeometry.b, PrismGeometry.c] {
                path.move(to: g)
                path.addLine(to: PrismGeometry.point(vertex, in: rect))
            }
            context.clip(to: PrismTriangle().path(in: rect))
            let color: Color = switch style {
            case .spectral: .white.opacity(0.95)
            case .onLight: .white.opacity(0.75)
            case .monochrome: .white.opacity(0.0)
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(0.6, canvasSize.width * 0.014), lineCap: .round))
        }
        .opacity((facetAssembly?.min() ?? assembly) >= 0.98 ? 1 : 0)
        .blendMode(style.isSpectral ? .plusLighter : .normal)
        .allowsHitTesting(false)
    }

    private func sweepBand(_ position: Double) -> some View {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0), location: 0),
                .init(color: .white.opacity(0.85), location: 0.5),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .frame(width: size * 0.35, height: size * 1.4)
        .rotationEffect(.degrees(18))
        .offset(x: (position - 0.5) * size * 1.3)
        .mask(PrismTriangle().frame(width: size, height: size))
        .blendMode(.plusLighter)
        .allowsHitTesting(false)
    }
}

extension PrismLogoMark.Style {
    var isSpectral: Bool {
        if case .spectral = self { return true }
        return false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

#Preview("PrismLogoMark") {
    HStack(spacing: 30) {
        PrismLogoMark(size: 120)
            .padding(30).background(.black)
        PrismLogoMark(size: 120, style: .onLight)
            .padding(30).background(.white)
        PrismLogoMark(size: 120, style: .monochrome(.gray))
            .padding(30).background(.white)
        PrismLogoMark(size: 24)
            .padding(10).background(.black)
    }
}
