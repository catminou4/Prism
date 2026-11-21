import SwiftUI
import PrismDesign

/// Custom navigation stack: pages slide in from the trailing edge with a fade while the
/// page below recedes slightly. Every page stays alive (scroll positions are preserved),
/// hidden pages are excluded from hit-testing/accessibility and told they are inactive.
struct PageStack<Root: View>: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.isPageActive) private var isSectionActive
    let section: SidebarItem
    @ViewBuilder var root: Root

    var body: some View {
        let path = navigation.stacks[section] ?? []
        ZStack {
            page(root, depth: 0, count: path.count)
            ForEach(Array(path.enumerated()), id: \.element.id) { index, entry in
                page(RouteDestination(route: entry.route), depth: index + 1, count: path.count)
                    .transition(.pagePush)
                    .zIndex(Double(index + 1))
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
