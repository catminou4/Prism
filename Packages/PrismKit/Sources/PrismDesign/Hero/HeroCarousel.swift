import SwiftUI

/// Auto-advancing hero carousel: 0.8 s cross-fade with a slight parallax, thin `‹ ›` chevrons
/// on hover, page dots, ←/→ when focused. Auto-advance pauses on hover, when the window is
/// inactive or occluded, and under Reduce Motion.
public struct HeroCarousel<Item: Identifiable, Content: View>: View {
    private let items: [Item]
    private let interval: Double
    private let height: CGFloat?
    private let showsDots: Bool
    private let content: (Item) -> Content
    @Binding private var externalIndex: Int?

    @State private var index = 0
    @State private var direction: Edge = .trailing
    @State private var hovering = false
    @State private var isWindowVisible = true
    @Environment(\.prismSnapshotHover) private var forcedHover
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        items: [Item],
        interval: Double = PrismMotion.heroInterval,
        height: CGFloat? = nil,
        showsDots: Bool = true,
        index: Binding<Int?> = .constant(nil),
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.interval = interval
        self.height = height
        self.showsDots = showsDots
        self.content = content
        _externalIndex = index
    }

    private var isHovered: Bool { hovering || forcedHover }

    private var currentIndex: Int { items.isEmpty ? 0 : min(index, items.count - 1) }

    private var isAutoAdvancing: Bool {
        items.count > 1 && !isHovered && appearsActive && isWindowVisible && !reduceMotion && interval > 0
    }

    public var body: some View {
        ZStack {
            Color.black
            if items.indices.contains(currentIndex) {
                let item = items[currentIndex]
                content(item)
                    .id(item.id)
                    .transition(pageTransition)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottom) {
            if showsDots && items.count > 1 {
                PageDots(count: items.count, index: currentIndex) { go(to: $0) }
                    .padding(.bottom, 20)
            }
        }
        .overlay { chevrons }
        .background { WindowOcclusionReader(isVisible: $isWindowVisible) }
        .onHover { inside in withAnimation(PrismMotion.quickFade) { hovering = inside } }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { go(to: currentIndex - 1); return .handled }
        .onKeyPress(.rightArrow) { go(to: currentIndex + 1); return .handled }
        .task(id: TimerKey(index: currentIndex, running: isAutoAdvancing)) {
            guard isAutoAdvancing else { return }
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            go(to: currentIndex + 1)
        }
        .onChange(of: externalIndex) { _, newValue in
            if let newValue, newValue != currentIndex { go(to: newValue) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityScrollAction { edge in
            switch edge {
            case .leading, .top: go(to: currentIndex - 1)
            default: go(to: currentIndex + 1)
            }
        }
    }

    private struct TimerKey: Hashable {
        let index: Int
        let running: Bool
    }

    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let shift: CGFloat = 36
        let insertion = AnyTransition.opacity.combined(with: .offset(x: direction == .trailing ? shift : -shift))
        let removal = AnyTransition.opacity.combined(with: .offset(x: direction == .trailing ? -shift * 0.5 : shift * 0.5))
        return .asymmetric(insertion: insertion, removal: removal)
    }

    private func go(to target: Int) {
        guard items.count > 1 else { return }
        let wrapped = (target % items.count + items.count) % items.count
        guard wrapped != currentIndex else { return }
        let forward = target > currentIndex
        direction = forward ? .trailing : .leading
        withAnimation(reduceMotion ? .easeInOut(duration: 0.4) : PrismMotion.heroFade) {
            index = wrapped
        }
        if externalIndex != nil { externalIndex = wrapped }
    }

    private var chevrons: some View {
        HStack {
            HeroChevron(systemName: "chevron.compact.left", label: "Précédent") { go(to: currentIndex - 1) }
            Spacer()
            HeroChevron(systemName: "chevron.compact.right", label: "Suivant") { go(to: currentIndex + 1) }
        }
        .padding(.horizontal, 10)
        .opacity(isHovered && items.count > 1 ? 1 : 0)
        .allowsHitTesting(isHovered && items.count > 1)
    }
}

/// Very thin, large, background-less chevron used at the hero edges.
struct HeroChevron: View {
    let systemName: String
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.white.opacity(isHovered ? 1 : 0.75))
                .shadow(color: .black.opacity(0.35), radius: 6)
                .frame(width: 36, height: 80)
                .contentShape(.rect)
        }
        .buttonStyle(.pressable)
        .onHover { isHovered = $0 }
        .focusEffectDisabled()
        .accessibilityLabel(Text(label))
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
