import SwiftUI

nonisolated struct DetailRating: Equatable, Sendable {
    enum Source: String, Sendable {
        case tmdb = "TMDB"
        case provider = "Catalogue IPTV"
    }

    let value: Double
    let source: Source

    static func preferred(tmdb: Double?, voteCount: Int? = nil, provider: [Double?]) -> Self? {
        if voteCount != 0, let tmdb, isValid(tmdb) {
            return Self(value: tmdb, source: .tmdb)
        }
        guard let value = provider.lazy.compactMap({ $0 }).first(where: isValid) else { return nil }
        return Self(value: value, source: .provider)
    }

    private static func isValid(_ value: Double) -> Bool {
        (0.1...10).contains(value)
    }

    var formatted: String { value.formatted(.number.precision(.fractionLength(1))) }
    var accessibleDescription: String { "\(formatted) sur 10, \(source.rawValue)" }
}

struct TitleRatingPanel: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    let rating: DetailRating

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle().strokeBorder(.secondary.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: CGFloat(visible || reduceMotion ? rating.value / 10 : 0))
                    .stroke(.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .semibold))
            }
            .frame(width: 38, height: 38)
            .padding(1)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(rating.formatted) / 10")
                    .font(.system(size: 18, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText(value: rating.value))
                Text(rating.source.rawValue)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(minWidth: 170, alignment: .leading)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Note")
        .accessibilityValue(rating.accessibleDescription)
        .onScrollVisibilityChange(threshold: 0.55) { onScreen in
            if onScreen { visible = true }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.46), value: visible)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: rating)
    }
}
