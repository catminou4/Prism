import Foundation
import Observation
import SwiftUI
import PrismCore
import PrismDesign

/// Top-level sections shown in the sidebar.
public enum SidebarItem: Hashable, Sendable {
    case search, home, live, movies, series
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

/// Sidebar selection + one independent page stack per section (each keeps its scroll position).
@MainActor
@Observable
public final class NavigationModel {
    public private(set) var selection: SidebarItem = .home
    public private(set) var stacks: [SidebarItem: [PageEntry]] = [:]

    public init(selection: SidebarItem = .home) {
        self.selection = selection
    }

    public var path: [PageEntry] { stacks[selection] ?? [] }
    public var canGoBack: Bool { !path.isEmpty }

    /// Selecting the current section again pops it to its root (Apple TV behaviour).
    public func select(_ item: SidebarItem) {
        if item == selection {
            popToRoot()
        } else {
            selection = item
        }
    }

    public func push(_ route: Route) {
        if path.last?.route == route { return }
        withAnimation(PrismMotion.standard) {
            stacks[selection, default: []].append(PageEntry(route))
        }
    }

    public func pop() {
        guard canGoBack else { return }
        withAnimation(PrismMotion.standard) {
            _ = stacks[selection]?.popLast()
        }
    }

    public func popToRoot() {
        guard canGoBack else { return }
        withAnimation(PrismMotion.standard) {
            stacks[selection] = []
        }
    }

    /// Switches section and pushes a route (e.g. a search result opening a title).
    public func open(_ route: Route, in item: SidebarItem? = nil) {
        if let item, item != selection { selection = item }
        push(route)
    }

    /// Drops pages that reference a removed source.
    public func removeRoutes(for source: SourceID) {
        for key in stacks.keys {
            stacks[key]?.removeAll { $0.route == .source(source) }
        }
        if selection == .source(source) { selection = .home }
    }
}

extension EnvironmentValues {
    /// `false` for pages hidden below the top of a page stack or in an unselected section:
    /// use it to pause timers (hero carousel), video previews and polling.
    @Entry public var isPageActive: Bool = true
}
