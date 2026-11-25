import SwiftUI

/// Subtle skeleton block with a slow highlight sweep (loading shelves/grids).
///
/// The sweep only animates while it can be seen: pages keep their skeletons mounted at
/// opacity 0 (page stacks) or in unselected sections, and without gating the perpetual
/// `PhaseAnimator` composites forever offscreen. Same signals as the hero/poster wall:
/// Reduce Motion, app/scene activity, page visibility and window occlusion.
public struct ShimmerPlaceholder: View {
    private let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.isPageActive) private var isPageActive
    @State private var isWindowVisible = true

    public init(cornerRadius: CGFloat = PrismMetrics.wideRadius) {
        self.cornerRadius = cornerRadius
    }

    private var animates: Bool {
        !reduceMotion && appearsActive && isPageActive && isWindowVisible
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.06))
            .overlay {
                if animates {
                    PhaseAnimator([false, true]) { phase in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .visualEffect { content, proxy in
                            content.offset(x: phase ? proxy.size.width : -proxy.size.width)
                        }
                    } animation: { phase in
                        phase ? .linear(duration: 1.4) : .linear(duration: 0)
                    }
                    .clipShape(shape)
                }
            }
            .background {
                WindowOcclusionReader(isVisible: $isWindowVisible)
            }
            .accessibilityLabel("Chargement")
    }
}

/// A shelf-shaped skeleton: header bar + a row of placeholder cards.
public struct ShelfSkeleton: View {
    public enum Style: Sendable {
        case posters, wide
    }

    private let style: Style
    private let count: Int

    public init(style: Style = .posters, count: Int = 7) {
        self.style = style
        self.count = count
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing + 4) {
            ShimmerPlaceholder(cornerRadius: 4)
                .frame(width: 160, height: 16)
            // The row never dictates the container width (it is clipped instead).
            Color.clear
                .frame(height: rowHeight)
                .overlay(alignment: .leading) { row }
                .clipped()
        }
        .padding(.horizontal, PrismMetrics.contentMargin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Chargement")
    }

    private var rowHeight: CGFloat {
        switch style {
        case .posters: PrismMetrics.posterWidth / PrismMetrics.posterAspectRatio
        case .wide: WideCard<EmptyView>.height(forWidth: PrismMetrics.wideCardWidth, twoLines: false)
        }
    }

    private var row: some View {
            HStack(spacing: PrismMetrics.cardSpacing) {
                ForEach(0..<count, id: \.self) { _ in
                    switch style {
                    case .posters:
                        ShimmerPlaceholder(cornerRadius: PrismMetrics.posterRadius)
                            .frame(width: PrismMetrics.posterWidth, height: PrismMetrics.posterWidth / PrismMetrics.posterAspectRatio)
                    case .wide:
                        ShimmerPlaceholder(cornerRadius: PrismMetrics.wideRadius)
                            .frame(width: PrismMetrics.wideCardWidth, height: WideCard<EmptyView>.height(forWidth: PrismMetrics.wideCardWidth, twoLines: false))
                    }
                }
            }
            .fixedSize()
    }
}

#Preview("ShimmerPlaceholder") {
    VStack(spacing: 30) {
        ShelfSkeleton(style: .wide, count: 4)
        ShelfSkeleton(style: .posters, count: 6)
    }
    .frame(width: 1000)
    .padding(.vertical, 30)
}
