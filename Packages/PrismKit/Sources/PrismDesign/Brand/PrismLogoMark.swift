import SwiftUI

/// Prism’s monogram on a transparent background, legible at sidebar and icon sizes.
public struct PrismLogoMark: View {
    public enum Style: Sendable {
        /// Chooses graphite or white according to the current appearance.
        case adaptive
        case onLight
        case onDark
        case monochrome(Color)

        @available(*, deprecated, renamed: "adaptive")
        public static var spectral: Self { .adaptive }
    }

    private let size: CGFloat
    private let style: Style
    private let stemProgress: Double
    private let bowlProgress: Double
    @Environment(\.colorScheme) private var colorScheme

    public init(size: CGFloat = 64, style: Style = .adaptive) {
        self.init(size: size, style: style, stemProgress: 1, bowlProgress: 1)
    }

    init(size: CGFloat, style: Style, stemProgress: Double, bowlProgress: Double) {
        self.size = size
        self.style = style
        self.stemProgress = stemProgress
        self.bowlProgress = bowlProgress
    }

    public var body: some View {
        let tones = palette
        ZStack {
            PrismMonogramPlane(part: .stem)
                .fill(tones.stem)
                .opacity(stemProgress)
                .offset(x: -size * 0.12 * (1 - stemProgress), y: size * 0.05 * (1 - stemProgress))
            PrismMonogramPlane(part: .bowl)
                .fill(tones.bowl)
                .opacity(bowlProgress)
                .offset(x: size * 0.15 * (1 - bowlProgress), y: -size * 0.05 * (1 - bowlProgress))
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("Prism")
    }

    private var palette: (stem: Color, bowl: Color) {
        let light = (Color(white: 0.13), Color(white: 0.31))
        let dark = (Color.white, Color(white: 0.79))
        return switch style {
        case .adaptive: colorScheme == .dark ? dark : light
        case .onLight: light
        case .onDark: dark
        case .monochrome(let color): (color, color)
        }
    }
}

#Preview("PrismLogoMark") {
    HStack(spacing: 30) {
        PrismLogoMark(size: 120, style: .onDark)
            .padding(30).background(.black)
        PrismLogoMark(size: 120, style: .onLight)
            .padding(30).background(.white)
        PrismLogoMark(size: 120, style: .monochrome(.gray))
            .padding(30).background(.white)
        PrismLogoMark(size: 24, style: .onDark)
            .padding(10).background(.black)
    }
}
