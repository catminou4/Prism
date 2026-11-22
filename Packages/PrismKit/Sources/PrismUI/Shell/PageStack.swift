import SwiftUI
import PrismDesign

/// Custom navigation stack: pages slide in from the trailing edge with a fade while the
/// page below recedes slightly. Pages below the top stay mounted (scroll positions are
/// preserved) down to `maxMountedPages`; deeper pages are destroyed so they stop
/// observing `AppModel`/`LibraryStore` at opacity 0 — every progress tick or feed
/// refresh would otherwise re-evaluate them. Hidden pages are excluded from
/// hit-testing/accessibility and told they are inactive.
struct PageStack<Root: View>: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isSectionActive
    let section: SidebarItem
    @ViewBuilder var root: Root

    /// Pushed pages kept alive under the top one (plus the root). Deeper routes stay
    /// in `NavigationModel` — only their view state (scroll position) is lost
    /// when navigating back past this depth.
    private static var maxMountedPages: Int { 7 }

    var body: some View {
        // `pages(in:)` ne souscrit qu'à la cellule de cette section : une
        // navigation dans une autre section ne réévalue pas cette pile.
        let path = navigation.pages(in: section)
        // Only the top `maxMountedPages` entries stay mounted; the suffix keeps the
        // most recent pages, which are the likeliest back-navigation targets.
        let mountedCount = min(path.count, Self.maxMountedPages)
        let mounted = path.suffix(mountedCount)
        let firstDepth = path.count - mountedCount + 1
        ZStack {
            page(root, depth: 0, count: path.count)
            ForEach(Array(mounted.enumerated()), id: \.element.id) { index, entry in
                page(RouteDestination(route: entry.route), depth: firstDepth + index, count: path.count)
                    .transition(.pagePush)
                    .zIndex(Double(firstDepth + index))
            }
        }
        .onKeyPress(.escape) {
            guard !path.isEmpty else { return .ignored }
            navigation.pop()
            return .handled
        }
    }

    private func page(_ content: some View, depth: Int, count: Int) -> some View {
        let isTop = depth == count
        return content
            .environment(\.isPageActive, isSectionActive && isTop)
            .opacity(isTop ? 1 : 0)
            .offset(x: isTop ? 0 : -36)
            .allowsHitTesting(isTop)
            .accessibilityHidden(!isTop)
    }
}

/// Maps a route to its screen. Feature folders own the destination views.
struct RouteDestination: View {
    let route: Route

    var body: some View {
        switch route {
        case .title(let id):
            TitleDetailView(titleID: id)
        case .collection(let collection):
            CollectionView(collection: collection)
        case .source(let id):
            SourceDetailView(sourceID: id)
        }
    }
}

private struct PagePushModifier: ViewModifier {
    let progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(x: (1 - progress) * 72)
    }
}

extension AnyTransition {
    static var pagePush: AnyTransition {
        .modifier(active: PagePushModifier(progress: 0), identity: PagePushModifier(progress: 1))
    }
}

/// Propagates a scroll view's phase to `\.prismIsScrollingContent` (defined in
/// PrismDesign) so cards can suspend their hover lift/shadow while the page scrolls.
/// Apply to the `ScrollView` itself — the environment reaches its content.
struct ScrollPhaseEnvironment: ViewModifier {
    @State private var isScrolling = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                if isScrolling != phase.isScrolling { isScrolling = phase.isScrolling }
            }
            .environment(\.prismIsScrollingContent, isScrolling)
    }
}

extension View {
    /// À poser sur un `ScrollView` dont le contenu contient des cartes.
    func prismScrollPhase() -> some View {
        modifier(ScrollPhaseEnvironment())
    }
}
