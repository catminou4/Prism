import SwiftUI

/// Live channel tile: logo centred on a gradient sampled from the logo, number, `EN DIRECT`,
/// and a caption band with the programme title + progress.
public struct ChannelTile<MenuContent: View>: View {
    private let logoURL: URL?
    private let name: String
    private let number: Int?
    private let programTitle: String?
    private let progress: Double?
    private let isLive: Bool
    private let tint: PrismTint?
    private let width: CGFloat?
    private let action: (() -> Void)?
    private let menu: MenuContent
    @State private var sampled: RGBA?
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(
        logoURL: URL?,
        name: String,
        number: Int? = nil,
        programTitle: String? = nil,
        progress: Double? = nil,
        isLive: Bool = true,
        tint: PrismTint? = nil,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder menu: () -> MenuContent
    ) {
        self.logoURL = logoURL
        self.name = name
        self.number = number
        self.programTitle = programTitle
        self.progress = progress
        self.isLive = isLive
        self.tint = tint
        self.width = width
        self.action = action
        self.menu = menu()
    }

    /// Tile height for a given width.
    public static func height(forWidth width: CGFloat) -> CGFloat {
        (width / PrismMetrics.wideAspectRatio).rounded() + 38
    }

    public var body: some View {
        let w = width ?? shelfWidth ?? PrismMetrics.channelTileWidth
        let artworkHeight = (w / PrismMetrics.wideAspectRatio).rounded()
        let size = CGSize(width: w, height: Self.height(forWidth: w))
        CardContainer(accessibilityLabel: accessibilityText, action: action, menu: menu) { isHovered in
            ArtworkSurface(radius: PrismMetrics.wideRadius) {
                ZStack(alignment: .top) {
                    background
                    logo(size: CGSize(width: w * 0.46, height: artworkHeight * 0.42))
                        .frame(width: w, height: artworkHeight)
                }
                .frame(width: size.width, height: size.height, alignment: .top)
                .overlay(alignment: .topLeading) {
                    if let number {
                        Text(number, format: .number.grouping(.never))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isLive { LiveBadge(pulsing: false, compact: true).padding(10) }
                }
                .overlay(alignment: .bottom) { captionBlock(isHovered: isHovered) }
            }
            .frame(width: size.width, height: size.height)
        }
        .task(id: logoURL) {
            guard let logoURL else { return }
            if let rgba = await ImagePipeline.shared.averageRGBA(for: logoURL), !Task.isCancelled {
                withAnimation(PrismMotion.imageFade) { sampled = rgba }
            }
        }
    }

    private var background: some View {
        let colors = gradientColors
        return ZStack {
            LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [.white.opacity(0.14), .clear], center: UnitPoint(x: 0.5, y: 0.25), startRadius: 0, endRadius: 160)
            LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
        }
    }

    /// Deep, slightly desaturated tones so white logos and text stay legible.
    private var gradientColors: (Color, Color) {
        if let sampled, sampled.saturation > 0.18 {
            let lum = max(sampled.luminance, 0.05)
            let top = sampled.scaled(brightness: min(1.0, 0.55 / lum) * 0.9)
            let bottom = sampled.scaled(brightness: min(1.0, 0.22 / lum))
            return (top.color, bottom.color)
        }
        // Tint fallback: deep, desaturated version of the source tint.
        let pair = (tint ?? PrismTint.forSeed(name)).gradientColors
        return (pair.bottom.mix(with: .black, by: 0.35), pair.bottom.mix(with: .black, by: 0.72))
    }

    @ViewBuilder private func logo(size: CGSize) -> some View {
        if let logoURL {
            RemoteImage(url: logoURL, size: size, contentMode: .fit, placeholderSeed: name, showsPlaceholder: false)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .background {
                    Text(Monogram.initials(from: name))
                        .font(.system(size: size.height * 0.7, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white.opacity(sampled == nil ? 0.9 : 0))
                }
        } else {
            Text(name)
                .font(.system(size: 22, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .frame(width: size.width * 1.4, height: size.height * 1.4)
        }
    }

    private func captionBlock(isHovered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(programTitle ?? name)
                .font(PrismFont.cardCaption)
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let progress {
                    ProgressCapsule(fraction: progress, width: 28, height: 4).padding(.trailing, 2)
                }
                Text(programTitle == nil ? (number.map { "Chaîne \($0)" } ?? "En direct") : name)
                    .font(PrismFont.cardMeta.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if MenuContent.self != EmptyView.self {
                    CardMenuButton(isHovered: isHovered, menu: menu).padding(.trailing, -6)
                }
            }
            .frame(height: 16)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.bottom, 9)
    }

    private var accessibilityText: Text {
        var parts = [name]
        if let number { parts.append("chaîne \(number)") }
        if let programTitle { parts.append(programTitle) }
        if isLive { parts.append("en direct") }
        return Text(parts.joined(separator: ", "))
    }
}

extension ChannelTile where MenuContent == EmptyView {
    public init(
        logoURL: URL?, name: String, number: Int? = nil, programTitle: String? = nil, progress: Double? = nil,
        isLive: Bool = true, tint: PrismTint? = nil, width: CGFloat? = nil, action: (() -> Void)? = nil
    ) {
        self.init(logoURL: logoURL, name: name, number: number, programTitle: programTitle, progress: progress, isLive: isLive, tint: tint, width: width, action: action) { EmptyView() }
    }
}

#Preview("ChannelTile") {
    HStack(spacing: 20) {
        ChannelTile(logoURL: nil, name: "France 2", number: 2, programTitle: "Journal de 20 heures", progress: 0.4, tint: .blue)
        ChannelTile(logoURL: nil, name: "Canal+ Sport", number: 45, programTitle: "Ligue 1 : PSG – OM", progress: 0.7, tint: .red)
    }
    .padding(40)
}
