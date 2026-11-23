import SwiftUI

/// A hero carousel with horizontal scrolling, arrow keys, page dots and explicit controls.
/// Auto-advance pauses on hover, when inactive or occluded, and under Reduce Motion.
public struct HeroCarousel<Item: Identifiable, Content: View>: View {
    private let items: [Item]
    private let interval: Double
    private let height: CGFloat?
    private let showsDots: Bool
    private let isInteractive: Bool
    private let extendsUnderSidebar: Bool
    private let canWrapForward: Bool
    private let content: (Item) -> Content
    @Binding private var externalIndex: Int?

    @State private var index = 0
    @State private var visibleID: Item.ID?
    @State private var direction: Edge = .trailing
    @State private var transitionOrder: Double = 0
    @State private var hovering = false
    @State private var isWindowVisible = true
    @State private var scrollHitRegion = HeroScrollHitRegion()
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        items: [Item],
        interval: Double = PrismMotion.heroInterval,
        height: CGFloat? = nil,
        showsDots: Bool = true,
        index: Binding<Int?> = .constant(nil),
        isInteractive: Bool = true,
        extendsUnderSidebar: Bool = false,
        canWrapForward: Bool = true,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.interval = interval
        self.height = height
        self.showsDots = showsDots
        self.isInteractive = isInteractive
        self.extendsUnderSidebar = extendsUnderSidebar
        self.canWrapForward = canWrapForward
        self.content = content
        _externalIndex = index
        let initial = min(max(index.wrappedValue ?? 0, 0), max(items.count - 1, 0))
        _index = State(initialValue: initial)
        _visibleID = State(initialValue: items.indices.contains(initial) ? items[initial].id : nil)
    }

    private var currentIndex: Int {
        if let visibleID, let current = items.firstIndex(where: { $0.id == visibleID }) { return current }
        return min(max(index, 0), max(items.count - 1, 0))
    }

    /// Order-sensitive fingerprint of the item ids — same change detection as
    /// `items.map(\.id)` without allocating the id array on every evaluation.
    private var itemsSignature: Int {
        var signature = items.count
        for item in items {
            signature = signature &* 31 &+ item.id.hashValue
        }
        return signature
    }

    private var canPage: Bool { isInteractive && items.count > 1 }
    private var isAutoAdvancing: Bool {
        canPage && !hovering && appearsActive && isWindowVisible && !reduceMotion && interval > 0
    }

    public var body: some View {
        ZStack {
            Color.black
            if items.indices.contains(currentIndex) {
                let item = items[currentIndex]
                content(item)
                    .id(item.id)
                    .zIndex(transitionOrder)
                    .transition(pageTransition)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        // Keep page transitions clipped, then let the system extend their backdrop under the sidebar.
        .backgroundExtensionEffect(isEnabled: extendsUnderSidebar)
        .overlay(alignment: .bottom) { navigationControls }
        .background {
            WindowOcclusionReader(isVisible: $isWindowVisible)
            if canPage { HeroHorizontalScrollReader(region: scrollHitRegion) { go(to: currentIndex + $0) } }
        }
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            scrollHitRegion.frame = frame
        }
        .focusable(canPage)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            guard canPage else { return .ignored }
            go(to: currentIndex - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard canPage else { return .ignored }
            go(to: currentIndex + 1)
            return .handled
        }
        .task(id: TimerKey(index: currentIndex, running: isAutoAdvancing)) {
            guard isAutoAdvancing else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            go(to: currentIndex + 1)
        }
        .onChange(of: externalIndex) { _, newValue in
            if let newValue, newValue != currentIndex { go(to: newValue) }
        }
        .onChange(of: itemsSignature) { _, _ in
            let current = currentIndex
            index = current
            visibleID = items.indices.contains(current) ? items[current].id : nil
            if externalIndex != nil { externalIndex = current }
        }
        .accessibilityElement(children: .contain)
        .accessibilityScrollAction { edge in
            switch edge {
            case .leading: go(to: currentIndex - 1)
            case .trailing: go(to: currentIndex + 1)
            default: break
            }
        }
    }

    private struct TimerKey: Hashable {
        let index: Int
        let running: Bool
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let shift: CGFloat = 14
        let insertion = AnyTransition.opacity
            .combined(with: .scale(scale: 1.015))
            .combined(with: .offset(x: direction == .trailing ? shift : -shift))
        // Keep the old artwork underneath until the incoming one has covered it.
        let removal = AnyTransition.opacity.animation(.linear(duration: 0.01).delay(0.70))
        return .asymmetric(insertion: insertion, removal: removal)
    }

    private func go(to target: Int) {
        guard canPage else { return }
        if target >= items.count && !canWrapForward { return }
        let wrapped = (target % items.count + items.count) % items.count
        guard wrapped != currentIndex else { return }
        let forward = target > currentIndex
        direction = forward ? .trailing : .leading
        let animation: Animation = reduceMotion ? .easeOut(duration: 0.16) : PrismMotion.heroFade
        withAnimation(animation) {
            transitionOrder += 1
            index = wrapped
            visibleID = items[wrapped].id
        }
        if externalIndex != nil { externalIndex = wrapped }
    }

    @ViewBuilder private var navigationControls: some View {
        if items.count > 1 {
            ZStack(alignment: .trailing) {
                if showsDots {
                    PageDots(count: items.count, index: currentIndex) { go(to: $0) }
                        .frame(maxWidth: .infinity)
                }
                HStack(spacing: 8) {
                    GlassCircleButton(systemName: "chevron.left", size: 32, style: .dark, accessibilityLabel: "Sélection précédente") {
                        go(to: currentIndex - 1)
                    }
                    .help("Précédent (←)")
                    GlassCircleButton(systemName: "chevron.right", size: 32, style: .dark, accessibilityLabel: "Sélection suivante") {
                        go(to: currentIndex + 1)
                    }
                    .help("Suivant (→)")
                }
                .padding(.trailing, 22)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.bottom, 15)
        }
    }
}

#Preview("HeroCarousel") {
    struct Page: Identifiable { let id: Int; let title: String }
    let pages = [Page(id: 0, title: "Severance"), Page(id: 1, title: "Silo"), Page(id: 2, title: "Slow Horses")]
    return HeroCarousel(items: pages, interval: 4, height: 420) { page in
        HeroBackdrop(imageURL: nil, seed: page.title)
            .overlay(alignment: .bottomLeading) {
                Text(page.title).font(PrismFont.heroTitle).foregroundStyle(.white).padding(40)
            }
    }
    .frame(width: 1000)
}
