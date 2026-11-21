import SwiftUI

/// How a shelf sizes its cards.
nonisolated public enum ShelfSizing: Sendable, Hashable {
    /// Fixed card width.
    case fixed(CGFloat)
    /// Apple TV behaviour: as many whole columns of at least `minWidth` as fit the visible
    /// width; the next card peeks into the trailing margin.
    case columns(minWidth: CGFloat)

    public static let posters = ShelfSizing.columns(minWidth: PrismMetrics.posterMinWidth)
    public static let wide = ShelfSizing.columns(minWidth: PrismMetrics.wideCardMinWidth)
    public static let people = ShelfSizing.fixed(PrismMetrics.personDiameter)
}

/// Horizontal shelf: header + lazily loaded row of cards with view-aligned paging and
/// hover-revealed glass chevrons that page by the visible width.
///
/// The card closure receives the item; cards read their width from the environment
/// (`prismCardWidth`), so the row height is fixed before any image loads.
public struct Shelf<Item: Identifiable, Card: View>: View {
    private let title: String?
    private let subtitle: String?
    private let items: [Item]
    private let sizing: ShelfSizing
    private let spacing: CGFloat
    private let margin: CGFloat
    private let onHeaderTap: (() -> Void)?
    private let card: (Item) -> Card

    @State private var position = ScrollPosition(edge: .leading)
    @State private var edges = ScrollEdges()
    @State private var visibleWidth: CGFloat = 0
    @State private var hovering = false
    @Environment(\.prismSnapshotHover) private var forcedHover

    private var isHovered: Bool { hovering || forcedHover }

    public init(
        title: String?,
        subtitle: String? = nil,
        items: [Item],
        sizing: ShelfSizing = .posters,
        spacing: CGFloat = PrismMetrics.cardSpacing,
        margin: CGFloat = PrismMetrics.contentMargin,
        onHeaderTap: (() -> Void)? = nil,
        @ViewBuilder card: @escaping (Item) -> Card
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.sizing = sizing
        self.spacing = spacing
        self.margin = margin
        self.onHeaderTap = onHeaderTap
        self.card = card
    }

    /// Extra room inside the scroll view so the hover scale + shadow are not clipped.
    private static var liftInset: (top: CGFloat, bottom: CGFloat) { (24, 40) }

    private var itemWidth: CGFloat {
        switch sizing {
        case .fixed(let width): width
        case .columns(let minWidth): PrismMetrics.columnWidth(available: visibleWidth - margin * 2, minWidth: minWidth, spacing: spacing)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
            if let title {
                ShelfHeader(title, subtitle: subtitle, action: onHeaderTap)
                    .padding(.horizontal, margin)
                    // Above the row's transparent lift inset so the header stays clickable.
                    .zIndex(1)
            }
            row
        }
    }

    private var row: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: spacing) {
                ForEach(items) { item in
                    card(item)
                }
            }
            .scrollTargetLayout()
            // Room for the hover lift + shadow (the scroll view clips vertically).
            .padding(.top, Self.liftInset.top)
            .padding(.bottom, Self.liftInset.bottom)
        }
        // Hug the cards' height (a horizontal scroll view is vertically greedy otherwise).
        .fixedSize(horizontal: false, vertical: true)
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            ScrollEdges(geometry: geometry)
        } action: { _, newValue in
            edges = newValue
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { visibleWidth = $0 }
        .padding(.top, -Self.liftInset.top)
        .padding(.bottom, -Self.liftInset.bottom)
        .prismCardWidth(visibleWidth > 0 || sizing.isFixed ? itemWidth : nil)
        .overlay(alignment: .leading) { chevron(.leading) }
        .overlay(alignment: .trailing) { chevron(.trailing) }
        .onHover { inside in withAnimation(PrismMotion.quickFade) { hovering = inside } }
        .opacity(visibleWidth > 0 || sizing.isFixed ? 1 : 0)
    }

    @ViewBuilder private func chevron(_ edge: HorizontalEdge) -> some View {
        let canScroll = edge == .leading ? edges.canScrollBackward : edges.canScrollForward
        GlassCircleButton(
            systemName: edge == .leading ? "chevron.left" : "chevron.right",
            size: PrismMetrics.shelfChevronSize,
            accessibilityLabel: edge == .leading ? "Précédent" : "Suivant"
        ) {
            page(edge)
        }
        .padding(.horizontal, (margin - PrismMetrics.shelfChevronSize) / 2)
        .opacity(isHovered && canScroll ? 1 : 0)
        .allowsHitTesting(isHovered && canScroll)
        .accessibilityHidden(!canScroll)
    }

    private func page(_ edge: HorizontalEdge) {
        let page = max(visibleWidth - margin * 2 + spacing, 100)
        let target = edge == .leading ? max(edges.offset - page, edges.minOffset) : min(edges.offset + page, edges.maxOffset)
        withAnimation(PrismMotion.standard) {
            position.scrollTo(x: target)
        }
    }
}

extension ShelfSizing {
    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }
}

struct ScrollEdges: Equatable {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0

    init() {}

    init(geometry: ScrollGeometry) {
        offset = geometry.contentOffset.x
        minOffset = -geometry.contentInsets.leading
        maxOffset = max(minOffset, geometry.contentSize.width + geometry.contentInsets.trailing - geometry.containerSize.width)
        // Quantise so tiny scroll deltas don't invalidate the shelf.
        offset = offset.rounded()
    }

    var canScrollBackward: Bool { offset > minOffset + 1 }
    var canScrollForward: Bool { offset < maxOffset - 1 }
}

#Preview("Shelf") {
    struct Item: Identifiable { let id: Int }
    return ScrollView {
        VStack(alignment: .leading, spacing: PrismMetrics.shelfSpacing) {
            Shelf(title: "Continuer", items: (0..<10).map(Item.init), sizing: .wide, onHeaderTap: {}) { item in
                WideCard(imageURL: nil, seed: "w\(item.id)", caption: "S1, É\(item.id + 1) · 23 min", progress: 0.3, placeholderTitle: "Série \(item.id)")
            }
            Shelf(title: "Films populaires", subtitle: "Les plus regardés cette semaine.", items: (0..<20).map(Item.init), onHeaderTap: {}) { item in
                PosterCard(imageURL: nil, seed: "p\(item.id)", title: "Film \(item.id)")
            }
        }
        .padding(.vertical, 30)
    }
    .frame(width: 1000, height: 640)
}
