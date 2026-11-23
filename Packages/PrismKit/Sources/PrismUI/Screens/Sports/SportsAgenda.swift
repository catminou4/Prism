import Foundation
import PrismCore
import PrismData

/// The programme for one day, or everything airing now when no day is selected.
nonisolated struct SportsAgenda {
    struct Section: Identifiable {
        enum Kind: Hashable {
            case live, upcoming, past

            var title: String {
                switch self {
                case .live: "En direct"
                case .upcoming: "À venir"
                case .past: "Résultats et diffusions passées"
                }
            }
        }

        let kind: Kind
        var fixtures: [SportsFixture]
        var id: Kind { kind }
    }

    let featured: SportsFixture?
    let sections: [Section]
    let otherPrograms: [SportsFixture]

    var isEmpty: Bool { featured == nil && sections.isEmpty && otherPrograms.isEmpty }

    init(fixtures: [SportsFixture], now: Date, day: Date?, sport: BroadcastSport?, calendar: Calendar = .current) {
        let entries = fixtures.filter { fixture in
            guard sport == nil || fixture.sport == sport else { return false }
            if let day { return calendar.isDate(fixture.startsAt, inSameDayAs: day) }
            return fixture.isAiring(at: now)
        }
        let identified = entries.filter(\.isIdentifiedMatch)
        let main = identified.isEmpty ? entries.filter { !$0.isCompanionProgram } : identified
        otherPrograms = identified.isEmpty ? entries.filter(\.isCompanionProgram) : entries.filter { !$0.isIdentifiedMatch }

        var live = Section(kind: .live, fixtures: [])
        var upcoming = Section(kind: .upcoming, fixtures: [])
        var past = Section(kind: .past, fixtures: [])
        for fixture in main {
            if fixture.isAiring(at: now) {
                live.fixtures.append(fixture)
            } else if fixture.startsAt >= now, fixture.event == nil || fixture.event?.status == .scheduled {
                upcoming.fixtures.append(fixture)
            } else {
                past.fixtures.append(fixture)
            }
        }
        if !live.fixtures.isEmpty {
            let index = live.fixtures.firstIndex { !$0.liveBroadcasts(at: now).isEmpty } ?? 0
            featured = live.fixtures.remove(at: index)
        } else {
            featured = upcoming.fixtures.isEmpty ? nil : upcoming.fixtures.removeFirst()
        }
        sections = [live, upcoming, past].filter { !$0.fixtures.isEmpty }
    }
}
