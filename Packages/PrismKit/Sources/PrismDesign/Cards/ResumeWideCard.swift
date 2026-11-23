import SwiftUI

/// Artwork-led card for a title in progress, with the playback details over the image.
public struct ResumeWideCard<MenuContent: View>: View {
    private let imageURL: URL?
    private let title: String
    private let metadata: String
    private let progress: Double?
    private let action: () -> Void
    private let menu: () -> MenuContent
    @Environment(\.prismCardWidth) private var shelfWidth

    public init(
        imageURL: URL?, title: String, metadata: String, progress: Double?,
        action: @escaping () -> Void, @ViewBuilder menu: @escaping () -> MenuContent
    ) {
        self.imageURL = imageURL
        self.title = title
        self.metadata = metadata
        self.progress = progress
        self.action = action
        self.menu = menu
    }

    public var body: some View {
        let width = shelfWidth ?? PrismMetrics.wideCardWidth
        let size = CGSize(width: width, height: (width * 2 / 3).rounded())
        let percent = progress.flatMap { value in
            value.isFinite ? "\(Int((min(max(value, 0), 1) * 100).rounded())) % regardé" : nil
        }
        let label = [title, metadata, percent]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        CardContainer(accessibilityLabel: Text(label), action: action, menu: menu) { hovered in
            ArtworkSurface(radius: PrismMetrics.wideRadius) {
                RemoteImage(url: imageURL, size: size, placeholderSeed: title, placeholderStyle: .none)
                    .overlay(alignment: .bottom) {
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: size.height * 0.54)
                    }
                    .overlay(alignment: .bottomLeading) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(title)
                                .font(PrismFont.cardCaption)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 9, weight: .bold))
                                if let progress { ProgressCapsule(fraction: progress, width: 26, height: 4) }
                                Text(metadata)
                                    .font(PrismFont.cardMeta.weight(.semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                CardMenuButton(isHovered: hovered, menu: menu)
                            }
                            .foregroundStyle(.white.opacity(0.85))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}
