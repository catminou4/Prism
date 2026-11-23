import Foundation
import PrismCore
import SwiftUI

nonisolated struct PlaybackSourceGroup: Identifiable {
    let source: Source
    var options: [TitlePlaybackOption]
    var duplicateNumbers: [ContentID: Int] = [:]
    var id: SourceID { source.id }

    static func grouped(_ options: [TitlePlaybackOption]) -> [Self] {
        var indexes: [SourceID: Int] = [:]
        var groups: [Self] = []
        for option in options {
            let source = option.titleEdition.source
            if let index = indexes[source.id] {
                groups[index].options.append(option)
            } else {
                indexes[source.id] = groups.count
                groups.append(Self(source: source, options: [option]))
            }
        }
        for index in groups.indices {
            let equivalent = Dictionary(grouping: groups[index].options) { option in
                EditionLabel(language: option.titleEdition.edition.title, format: option.label)
            }
            for matches in equivalent.values where matches.count > 1 {
                for (number, option) in matches.enumerated() {
                    groups[index].duplicateNumbers[option.id] = number + 1
                }
            }
        }
        return groups
    }

    private struct EditionLabel: Hashable {
        let language: String
        let format: String
    }
}
