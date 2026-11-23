import Observation
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
    private let posterCaptionHeight: CGFloat?
    private let onHeaderTap: (() -> Void)?
    private let posterArtwork: KeyPath<Item, URL?>?
    private let card: (Item) -> Card

    @State private var leadingItem: Item.ID?
    @State private var warmBox = WarmBox()
    @State private var viewport = ShelfViewport()
    @State private var measuredWidth: CGFloat = 0
    @State private var hovering = false
    @State private var rowScrolling = false
    @Environment(\.prismShelfViewportWidth) private var layoutWidth
    @Environment(\.prismSnapshotHover) private var forcedHover
    @Environment(\.prismIsScrollingContent) private var parentRowIsScrolling
    @Environment(\.prismScrollActivity) private var scrollActivity
    @ScrollingContent private var isScrollingContent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    private var isHovered: Bool { (hovering || forcedHover) && !isScrollingContent }

    public init(
        title: String?,
        subtitle: String? = nil,
        items: [Item],
        sizing: ShelfSizing = .posters,
        spacing: CGFloat = PrismMetrics.cardSpacing,
        margin: CGFloat = PrismMetrics.contentMargin,
        posterCaptionHeight: CGFloat? = nil,
        onHeaderTap: (() -> Void)? = nil,
        posterArtwork: KeyPath<Item, URL?>? = nil,
        @ViewBuilder card: @escaping (Item) -> Card
    ) {
        self.title = title
        self.subtitle = subtitle
        self.items = items
        self.sizing = sizing
        self.spacing = spacing
        self.margin = margin
        self.posterCaptionHeight = posterCaptionHeight
        self.onHeaderTap = onHeaderTap
        self.posterArtwork = posterArtwork
        self.card = card
    }

    /// Extra room inside the scroll view so the hover scale + shadow are not clipped.
    private static var liftInset: (top: CGFloat, bottom: CGFloat) { (24, 40) }

    private var itemWidth: CGFloat {
        switch sizing {
        case .fixed(let width): width
        case .columns(let minWidth):
            PrismMetrics.columnWidth(available: (layoutWidth ?? measuredWidth) - margin * 2, minWidth: minWidth, spacing: spacing)
        }
    }

    public var body: some View {
        let warm = warmRequest
        VStack(alignment: .leading, spacing: PrismMetrics.shelfHeaderSpacing) {
            if let title {
                ShelfHeader(title, subtitle: subtitle, action: onHeaderTap)
                    .padding(.horizontal, margin)
                    // Above the row's transparent lift inset so the header stays clickable.
                    .zIndex(1)
            }
            row
        }
        // Threshold crossings must not write @State: each write re-evaluates the whole
        // shelf (header + row) in the middle of a page scroll. The box debounces the
        // warm off the view tree instead.
        .onScrollVisibilityChange(threshold: 0.15) { visible in
            warmBox.setVisible(visible, warm, activity: scrollActivity)
        }
        // Row scrolling/resizing changes the warm target without a visibility event.
        .onChange(of: warm) { _, request in
            warmBox.refresh(request, activity: scrollActivity)
        }
        .onDisappear { warmBox.cancel() }
    }

    private struct WarmRequest: Equatable {
        let urls: [URL]
        let pixelSize: CGSize
    }

    private var warmRequest: WarmRequest? {
        guard let posterArtwork, !items.isEmpty else { return nil }
        let width = itemWidth
        let available = (layoutWidth ?? measuredWidth) - margin * 2
        guard available > 0, width > 0 else { return nil }
        let leading = leadingItem.flatMap { id in items.firstIndex { $0.id == id } } ?? 0
        let columns = max(1, Int((available + spacing) / (width + spacing)))
        let first = min(items.count, leading + columns)
        let urls = items.dropFirst(first).prefix(6).compactMap { $0[keyPath: posterArtwork] }
        guard !urls.isEmpty else { return nil }
        let size = CGSize(width: width, height: (width / PrismMetrics.posterAspectRatio).rounded())
        return WarmRequest(urls: urls, pixelSize: RemoteImage.pixelSize(forPointSize: size, scale: displayScale))
    }

    /// Debounced artwork warm-up for the posters just past the visible columns. Kept in a
    /// class (like `ShelfViewport`) so scroll callbacks mutate it without invalidating the
    /// shelf — class storage is invisible to SwiftUI observation.
    private final class WarmBox {
        private(set) var isVisible = false
        private var task: Task<Void, Never>?

        /// Visibility threshold crossed: remember it, then arm or cancel the pending warm.
        func setVisible(_ visible: Bool, _ request: WarmRequest?, activity: ScrollActivity?) {
            isVisible = visible
            schedule(visible ? request : nil, activity: activity)
        }

        /// The warm target changed (row scrolled, width changed, items swapped).
        func refresh(_ request: WarmRequest?, activity: ScrollActivity?) {
            schedule(isVisible ? request : nil, activity: activity)
        }

        /// The shelf left the view tree: drop any pending warm (mirrors the old `.task`
        /// cancellation on disappear). `isVisible` is kept — a still-visible shelf that
        /// comes back re-arms through `refresh`/`setVisible`.
        func cancel() {
            task?.cancel()
            task = nil
        }

        /// (Re)arms a ~150 ms debounce so a shelf passed mid-scroll never queues artwork;
        /// the latest call wins and `nil` cancels outright.
        private func schedule(_ request: WarmRequest?, activity: ScrollActivity?) {
            task?.cancel()
            task = nil
            guard let request else { return }
            let urls = request.urls
            let pixelSize = request.pixelSize
            task = Task.detached(priority: .utility) {
                try? await Task.sleep(for: .milliseconds(150))
                await activity?.waitUntilIdle()
                guard !Task.isCancelled else { return }
                ImagePipeline.shared.warm(urls, pixelSize: pixelSize)
            }
        }
    }

    private var row: some View {
        let viewportHeight = posterCaptionHeight.map {
            (itemWidth / PrismMetrics.posterAspectRatio).rounded() + $0 + Self.liftInset.top + Self.liftInset.bottom
        }
        return ScrollView(.horizontal) {
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
        // Poster shelves already know their cross-axis size before any cards are created.
        .frame(height: viewportHeight)
        .fixedSize(horizontal: false, vertical: viewportHeight == nil)
        // `.hidden` still shows legacy scrollers when macOS is set to always show them (mouse attached).
        .scrollIndicators(.never)
        .contentMargins(.horizontal, margin, for: .scrollContent)
        .defaultScrollAnchor(.leading, for: .initialOffset)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
        .scrollPosition(id: $leadingItem, anchor: .leading)
        // Cards suspend hover lift/shadow while this row (or an ancestor scroller) moves.
        .environment(\.prismIsScrollingContent, parentRowIsScrolling || rowScrolling)
        .onScrollPhaseChange { _, phase in
            rowScrolling = phase.isScrolling
        }
        .onScrollGeometryChange(for: ScrollEdges.self) { geometry in
            ScrollEdges(geometry: geometry)
        } action: { _, newValue in
            viewport.update(newValue)
            if layoutWidth == nil, measuredWidth != newValue.width { measuredWidth = newValue.width }
        }
        .padding(.top, -Self.liftInset.top)
        .padding(.bottom, -Self.liftInset.bottom)
        .prismCardWidth(itemWidth)
        // One overlay hosts both chevrons so `.animation(value:)` scopes to them alone —
        // on the row it propagated an animation attribute into every card's subtree each
        // time a shelf materialized (~8 cards × ~30 nodes of wasted attribute writes).
        .overlay {
            if isHovered {
                ShelfChevrons(viewport: viewport, margin: margin, page: page)
            }
        }
        .onHover { inside in
            if !inside || !isScrollingContent {
                withAnimation(PrismMotion.quickFade) { hovering = inside }
            }
        }
        .onChange(of: hovering && isScrollingContent) { _, shouldReset in
            if shouldReset { hovering = false }
        }
        .accessibilityScrollAction { edge in
            if edge == .leading && viewport.availability.backward { page(.leading) }
            if edge == .trailing && viewport.availability.forward { page(.trailing) }
        }
    }

    private func page(_ edge: HorizontalEdge) {
        guard !items.isEmpty else { return }
        let edges = viewport.edges
        let page = max(edges.width - margin * 2 + spacing, 100)
        let target = edge == .leading ? max(edges.offset - page, edges.minOffset) : min(edges.offset + page, edges.maxOffset)
        let offset = (target - edges.minOffset) / max(1, itemWidth + spacing)
        let index = Int(offset.rounded(edge == .leading ? .down : .up))
        let destination = items[min(max(index, 0), items.count - 1)].id
        withAnimation(reduceMotion ? nil : PrismMotion.standard) {
            leadingItem = destination
        }
    }
}

extension EnvironmentValues {
    /// The proposed width for full-width shelves in the library's content column.
    @Entry public var prismShelfViewportWidth: CGFloat? = nil
}

/// Paging uses the exact offsets. Only the chevron overlay observes edge availability.
@Observable private final class ShelfViewport {
    @ObservationIgnored private(set) var edges = ScrollEdges()
    private(set) var availability = ScrollAvailability()

    func update(_ edges: ScrollEdges) {
        self.edges = edges
        let availability = edges.availability
        if self.availability != availability { self.availability = availability }
    }
}

private struct ShelfChevrons: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewport: ShelfViewport
    let margin: CGFloat
    let page: (HorizontalEdge) -> Void

    var body: some View {
        let availability = viewport.availability
        HStack(spacing: 0) {
            chevron(.leading, visible: availability.backward)
            Spacer(minLength: 0)
            chevron(.trailing, visible: availability.forward)
        }
        .animation(PrismMotion.quickFade, value: availability)
    }

    @ViewBuilder private func chevron(_ edge: HorizontalEdge, visible: Bool) -> some View {
        if visible {
            Button { page(edge) } label: {
                Image(systemName: edge == .leading ? "chevron.left" : "chevron.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: PrismMetrics.shelfChevronSize, height: 52)
                    .contentShape(.capsule)
                    .prismGlass(.regular, in: .capsule, interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(edge == .leading ? "Précédent" : "Suivant")
            .padding(.horizontal, (margin - PrismMetrics.shelfChevronSize) / 2)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.8)))
        }
    }
}

private struct ScrollAvailability: Equatable {
    var backward = false
    var forward = false
}

private struct ScrollEdges: Equatable {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var width: CGFloat = 0

    init() {}

    init(geometry: ScrollGeometry) {
        offset = geometry.contentOffset.x
        width = geometry.containerSize.width
        minOffset = -geometry.contentInsets.leading
        maxOffset = max(minOffset, geometry.contentSize.width + geometry.contentInsets.trailing - width)
    }

    var availability: ScrollAvailability {
        ScrollAvailability(backward: offset > minOffset + 1, forward: offset < maxOffset - 1)
    }
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
