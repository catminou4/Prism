import Foundation
import PrismCore
import PrismDesign
import SwiftUI

struct PlaybackSourceGroup: Identifiable {
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

struct PlaybackSheetOptionRow: View {
    let option: TitlePlaybackOption
    let selected: Bool
    let focused: Bool
    let duplicateNumber: Int?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let edition = option.titleEdition
        let shape = RoundedRectangle(cornerRadius: 8)
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected ? .primary : .tertiary)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(edition.edition.title)
                    .font(.callout.weight(selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let duplicateNumber {
                    Text("Édition \(duplicateNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                ForEach(option.label.components(separatedBy: " · ").filter { !$0.isEmpty }, id: \.self) { label in
                    Text(label)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 4))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 40)
            .background(Color.primary.opacity(selected ? 0.10 : hovered ? 0.055 : 0), in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(focused ? 0.28 : 0), lineWidth: 1) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(PrismMotion.respecting(reduceMotion, .easeOut(duration: 0.14)), value: selected)
        .accessibilityLabel(edition.edition.title)
        .accessibilityValue(
            [duplicateNumber.map { "Édition \($0)" }, edition.source.name, option.label]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(edition.variant.rawName)
    }
}
