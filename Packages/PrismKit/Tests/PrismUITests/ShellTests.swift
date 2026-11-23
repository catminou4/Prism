import Foundation
import PrismCore
import PrismData
import Testing
@testable import PrismUI

@MainActor
@Suite("Coquille et navigation")
struct ShellTests {
    @Test func pushesStayInsideTheirSection() {
        let navigation = NavigationModel()
        navigation.push(.collection(.all(.movie)))

        #expect(navigation.pages(in: .home).count == 1)
        #expect(navigation.pages(in: .series).isEmpty)
        #expect(navigation.canGoBack)

        navigation.select(.series)
        #expect(navigation.pages(in: .series).isEmpty)
        // The home stack is preserved while another section is shown.
        #expect(navigation.pages(in: .home).count == 1)

        navigation.push(.title(TitleID(rawValue: "series:test:2020")))
        #expect(navigation.pages(in: .series).count == 1)
        #expect(navigation.pages(in: .home).count == 1)

        navigation.pop()
        #expect(navigation.pages(in: .series).isEmpty)
        #expect(navigation.pages(in: .home).count == 1)
    }

    @Test func reselectingASectionPopsItToRoot() {
        let navigation = NavigationModel()
        navigation.push(.collection(.watchlist))
        navigation.push(.title(TitleID(rawValue: "movie:test:2020")))
        #expect(navigation.path.count == 2)

        // `select` on the already-selected section pops instead of pushing.
        navigation.select(.home)
        #expect(navigation.path.isEmpty)
        #expect(navigation.selection == .home)
    }

    @Test func removingASourceDropsItsRoutes() {
        let navigation = NavigationModel()
        let source = SourceID("source-a")
        navigation.open(.source(source), in: .source(source))
        navigation.push(.collection(.all(.live)))
        #expect(navigation.pages(in: .source(source)).count == 2)

        navigation.removeRoutes(for: source)
        #expect(navigation.pages(in: .source(source)).map(\.route) == [.collection(.all(.live))])
        #expect(navigation.selection == .home)
    }

    @Test func sourceCountsAreComputedOnDemand() async throws {
        let model = await AppModel.preview()
        // `publish` no longer scans the catalogue for per-source counts: the only
        // reader is the source page, which warms them through `prepareSourceCounts`.
        #expect(model.sourceCounts.isEmpty)

        model.prepareSourceCounts()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while model.sourceCounts.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.sourceCounts.isEmpty)

        // A republication marks the counts stale but keeps the previous snapshot
        // on screen; the next `prepareSourceCounts` recomputes them in the background.
        await model.rebuild()
        #expect(!model.sourceCounts.isEmpty)
        model.prepareSourceCounts()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.sourceCounts.isEmpty)
    }
}
