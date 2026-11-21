import SwiftUI

/// macOS app icon artwork drawn on the 1024 pt grid: 824×824 squircle (radius ≈ 185),
/// dark vertical gradient with an inner glass highlight, the prism-play mark centred, and
/// the standard soft drop shadow inside the transparent margin.
public struct AppIconArtwork: View {
    private let size: CGFloat

    public init(size: CGFloat = 1024) {
        self.size = size
    }

    public var body: some View {
        let unit = size / 1024
        let box = 824 * unit
        let shape = RoundedRectangle(cornerRadius: 185.4 * unit, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(
                    colors: [Color(.sRGB, red: 0.18, green: 0.19, blue: 0.25), Color(.sRGB, red: 0.05, green: 0.05, blue: 0.08)],
                    startPoint: .top, endPoint: .bottom
                ))
                .overlay {
                    // Refracted-light halo behind the mark (spectral, heavily blurred).
                    Circle()
                        .fill(AngularGradient(
                            colors: [
                                Color(.sRGB, red: 0.35, green: 0.80, blue: 1.0),
                                Color(.sRGB, red: 0.52, green: 0.44, blue: 1.0),
                                Color(.sRGB, red: 0.95, green: 0.40, blue: 0.78),
                                Color(.sRGB, red: 1.0, green: 0.70, blue: 0.40),
                                Color(.sRGB, red: 0.35, green: 0.80, blue: 1.0),
                            ],
                            center: .center, angle: .degrees(-30)
                        ))
                        .frame(width: box * 0.62, height: box * 0.62)
                        .blur(radius: box * 0.12)
                        .opacity(0.48)
                        .offset(x: box * 0.02, y: box * 0.02)
                        .frame(width: box, height: box)
                        .clipShape(shape)
                }
                .overlay {
                    // Glass sheen at the top.
                    LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
                        .clipShape(shape)
                }
                .overlay {
                    // Inner highlight rim (bright top edge fading down).
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.06), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                        lineWidth: max(1, 5 * unit)
                    )
                }
                .frame(width: box, height: box)
                .shadow(color: .black.opacity(0.32), radius: 14 * unit, y: 10 * unit)

            PrismLogoMark(size: box * 0.62)
                .shadow(color: Color(.sRGB, red: 0.55, green: 0.6, blue: 1.0).opacity(0.35), radius: 26 * unit)
                .offset(x: box * 0.012, y: 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

#Preview("AppIconArtwork") {
    HStack(spacing: 20) {
        AppIconArtwork(size: 256)
        AppIconArtwork(size: 64)
        AppIconArtwork(size: 32)
    }
    .padding(30)
}
