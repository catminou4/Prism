import Observation
import SwiftUI

/// Shared by the content of a scroll view. Only views that actually read the phase
/// are invalidated, while the environment value keeps the same identity.
@Observable public final class ScrollActivity {
    public private(set) var isScrolling = false

    public init() {}

    public func update(isScrolling: Bool) {
        if self.isScrolling != isScrolling { self.isScrolling = isScrolling }
    }

    func waitUntilIdle() async {
        guard isScrolling else { return }
        for await scrolling in Observations({ self.isScrolling }) {
            if !scrolling { return }
        }
    }
}

extension EnvironmentValues {
    @Entry public var prismScrollActivity: ScrollActivity? = nil
}

@propertyWrapper struct ScrollingContent: DynamicProperty {
    @Environment(\.prismIsScrollingContent) private var isScrolling
    @Environment(\.prismScrollActivity) private var activity

    var wrappedValue: Bool { isScrolling || activity?.isScrolling == true }
}
