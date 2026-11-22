import SwiftUI

/// A station logo with channel and programme information on the surrounding page surface.
public struct ChannelTile<MenuContent: View>: View {
    private let logoURL: URL?
    private let name: String
    private let numberText: Text?
    private let programTitle: String?
    private let progress: Double?
    private let isLive: Bool
    private let width: CGFloat?
    private let action: (() -> Void)?
    private let menu: () -> MenuContent
    private let accessibilityText: Text
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(
        logoURL: URL?,
        name: String,
        number: Int? = nil,
        programTitle: String? = nil,
        progress: Double? = nil,
        isLive: Bool = true,
        tint _: PrismTint? = nil,
        width: CGFloat? = nil,
        action: (() -> Void)? = nil,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.logoURL = logoURL
        self.name = name
        numberText = number.map { Text($0, format: .number.grouping(.never)) }
        self.programTitle = programTitle
        self.progress = progress
        self.isLive = isLive
        self.width = width
        self.action = action
        self.menu = menu
        var parts = [name]
        if let number { parts.append("chaîne \(number)") }
        if let programTitle { parts.append(programTitle) }
        if isLive { parts.append("en direct") }
        accessibilityText = Text(parts.joined(separator: ", "))
    }

    /// Tile height for a given width.
    public static func height(forWidth width: CGFloat) -> CGFloat {
        (width / PrismMetrics.wideAspectRatio).rounded() + 44
    }

    public var body: some View {
        let w = width ?? shelfWidth ?? PrismMetrics.channelTileWidth
        let artworkHeight = (w / PrismMetrics.wideAspectRatio).rounded()
        CardContainer(accessibilityLabel: accessibilityText, action: action, hoverScale: 1.025, menu: menu) { isHovered in
            VStack(alignment: .leading, spacing: 8) {
                ArtworkSurface(radius: PrismMetrics.wideRadius) {
                    Color(white: logoURL == nil ? 0.16 : 0.36)
                        .overlay {
                            RemoteImage(
                                url: logoURL, size: CGSize(width: w * 0.56, height: artworkHeight * 0.54),
                                contentMode: .fit, placeholderSeed: name, placeholderTitle: name,
                                placeholderStyle: .channelLogo
                            )
                            .accessibilityHidden(true)
                        }
                        .overlay(alignment: .topLeading) {
                            if let numberText {
                                numberText
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.65))
                                    .padding(10)
                                    .accessibilityHidden(true)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if MenuContent.self != EmptyView.self {
                                CardMenuButton(isHovered: isHovered, menu: menu).padding(4)
                            }
                        }
                }
                .frame(width: w, height: artworkHeight)

                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(PrismFont.cardTitle)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let progress {
                            ProgressCapsule(fraction: progress, width: 26, height: 3, tint: .secondary, track: .primary.opacity(0.12))
                        } else if isLive {
                            Circle().fill(.secondary).frame(width: 4, height: 4)
                        }
                        Text(programTitle ?? (isLive ? "En direct" : ""))
                            .font(PrismFont.cardMeta)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: w, height: Self.height(forWidth: w), alignment: .topLeading)
        }
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
