import Foundation
import PrismCore
import PrismData

extension CatalogCommand {
    static func dumpCategories(_ catalog: Catalog) {
        for kind in [MediaKind.movie, .series] {
            print("\n== \(kind.rawValue) categories")
            print(catalog.categoryGroups(kind).map { "\($0.name)[\($0.itemCount)]" }.joined(separator: " · "))
        }
        var tags: [String: Int] = [:]
        for title in catalog.movies.prefix(40_000) { for tag in title.variants.flatMap(\.tags) { tags[tag, default: 0] += 1 } }
        print("\n== movie tags: " + tags.sorted { $0.value > $1.value }.prefix(60).map { "\($0.key):\($0.value)" }.joined(separator: " "))
        let sample = stride(from: 0, to: catalog.movies.count, by: max(1, catalog.movies.count / 40)).map { catalog.movies[$0] }
        print("\n== sample movies")
        for title in sample { print("  \(describe(title)) variants=\(title.variants.count) raw=\(title.primary?.rawName ?? "")") }
    }
}
