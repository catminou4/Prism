import Foundation
import Observation
import SwiftUI
import PrismCore
import PrismData
import PrismDesign

/// Top-level sections shown in the sidebar.
public enum SidebarItem: Hashable, Sendable {
    case search, home, live, sports, movies, series
    case watchlist, favorites, history
    case source(SourceID)
}

/// A "see all" collection pushed from a shelf header.
public enum CollectionRoute: Hashable, Sendable {
    case category(groupID: String)
    case all(MediaKind)
    case recentlyAdded(MediaKind)
    case topRated(MediaKind)
    case continueWatching
    case watchlist
    case related(TitleID)
    /// The full ranking behind a curated shelf.
    case curated(CurationQuery)
}

/// Pages pushed inside a section's page stack.
public enum Route: Hashable, Sendable {
    case title(TitleID)
    case collection(CollectionRoute)
    case source(SourceID)
}

/// One pushed page; `id` keeps identity stable across pops/pushes of equal routes.
public struct PageEntry: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let route: Route

    public init(_ route: Route) {
        self.id = UUID()
        self.route = route
    }
}

/// Pages pushed inside one section's stack, as an observable cell.
///
/// One cell per section (like `SourceImportState`): a push/pop writes only that
/// section's `pages`, so the other mounted `PageStack`s don't re-evaluate.
@MainActor
@Observable
final class SectionPath {
    var pages: [PageEntry] = []
}

/// Sidebar selection + one independent page stack per section (each keeps its scroll position).
@MainActor
@Observable
public final class NavigationModel {
    public private(set) var selection: SidebarItem = .home
    /// One cell per section that ever pushed a page; membership changes are rare.
    private var paths: [SidebarItem: SectionPath] = [:]
    /// Quand la section affichée a changé pour la dernière fois. `List(selection:)`
    /// ne re-notifie pas toujours la valeur identique : un clic sur la ligne déjà
    /// active doit déclencher `popToRoot`, sans confondre avec la bascule qui
    /// vient d'avoir lieu (le geste et la sélection arrivent quasi ensemble).
    public private(set) var lastSelectionChange = Date.distantPast

    public init(selection: SidebarItem = .home) {
        self.selection = selection
    }

    /// Pushed pages of `section` (empty at its root). Reading this subscribes only
    /// to that section's cell — pushes in other sections don't re-evaluate the page.
    public func pages(in section: SidebarItem) -> [PageEntry] {
        paths[section]?.pages ?? []
    }

    private func pathState(for section: SidebarItem) -> SectionPath {
        if let state = paths[section] { return state }
        let state = SectionPath()
        paths[section] = state
        return state
    }

    public var path: [PageEntry] { pages(in: selection) }
    public var canGoBack: Bool { !path.isEmpty }

    /// Selecting the current section again pops it to its root (Apple TV behaviour).
    public func select(_ item: SidebarItem) {
        if item == selection {
            popToRoot()
        } else {
            setSelection(item)
        }
    }

    private func setSelection(_ item: SidebarItem) {
        guard item != selection else { return }
        selection = item
        lastSelectionChange = .now
    }

    public func push(_ route: Route) {
        if path.last?.route == route { return }
        withAnimation(PrismMotion.standard) {
            pathState(for: selection).pages.append(PageEntry(route))
        }
    }

    public func pop() {
        guard canGoBack else { return }
        withAnimation(PrismMotion.standard) {
            _ = pathState(for: selection).pages.popLast()
        }
    }

    public func popToRoot() {
        guard canGoBack else { return }
        withAnimation(PrismMotion.standard) {
            pathState(for: selection).pages = []
        }
    }

    /// Switches section and pushes a route (e.g. a search result opening a title).
    public func open(_ route: Route, in item: SidebarItem? = nil) {
        if let item { setSelection(item) }
        push(route)
    }

    /// Drops pages that reference a removed source.
    public func removeRoutes(for source: SourceID) {
        for state in paths.values {
            state.pages.removeAll { $0.route == .source(source) }
        }
        if selection == .source(source) { setSelection(.home) }
    }
}

// `isPageActive` lives in PrismDesign (EnvironmentValues) so cards can read it.
