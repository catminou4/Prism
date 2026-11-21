import SwiftUI

/// The app icon uses the same mark as the sidebar, a graphite tile and a transparent margin.
public struct AppIconArtwork: View {
    private let size: CGFloat

    public init(size: CGFloat = 1024) {
        self.size = size
    }

    public var body: some View {
        let insetSize = size * 0.814
        let shape = RoundedRectangle(cornerRadius: insetSize * 0.224, style: .continuous)
        shape
            .fill(Color(white: 0.14))
            .overlay { shape.strokeBorder(.white.opacity(0.13), lineWidth: size * 0.003) }
            .overlay { PrismLogoMark(size: insetSize * 0.87, style: .onDark) }
            .frame(width: insetSize, height: insetSize)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview("AppIconArtwork") {
    HStack(spacing: 20) {
        AppIconArtwork(size: 256)
        AppIconArtwork(size: 64)
        AppIconArtwork(size: 32)
        AppIconArtwork(size: 16)
    }
    .padding(30)
}
