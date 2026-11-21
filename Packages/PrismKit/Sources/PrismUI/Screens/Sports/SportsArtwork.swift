import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

/// A single downsampled artwork slot shared by the shelf and the programme.
struct SportsArtwork: View {
    let fixture: SportsFixture
    let size: CGSize

    @State private var failedURLs: Set<URL> = []

    private var artworkURL: URL? {
        if let official = fixture.event?.artworkURL, !failedURLs.contains(official) { return official }
        return fixture.broadcasts.lazy.compactMap(\.program.iconURL).first { !failedURLs.contains($0) }
    }

    var body: some View {
        LinearGradient(colors: [Color(white: 0.24), Color(white: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .frame(width: size.width, height: size.height)
            .overlay { content }
            .clipShape(.rect(cornerRadius: PrismMetrics.wideRadius))
            .overlay {
                RoundedRectangle(cornerRadius: PrismMetrics.wideRadius)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if let artworkURL {
            RemoteImage(
                url: artworkURL, size: size, placeholderSeed: fixture.id, showsPlaceholder: false,
                onLoadFailure: { failedURLs.insert(artworkURL) }
            )
        } else {
            fallback
        }
    }

    @ViewBuilder private var fallback: some View {
        let diameter = max(28, min(58, size.height * 0.40))
        if let event = fixture.event {
            HStack(spacing: diameter * 0.4) {
                SportsArtworkBadge(logo: event.home.logoURL, monogram: Self.monogram(event.home), diameter: diameter)
                divider(diameter: diameter)
                SportsArtworkBadge(logo: event.away.logoURL, monogram: Self.monogram(event.away), diameter: diameter)
            }
        } else if let pair = fixture.guideOpponents {
            HStack(spacing: diameter * 0.4) {
                SportsArtworkBadge(logo: nil, monogram: Self.initials(pair.home), diameter: diameter)
                divider(diameter: diameter)
                SportsArtworkBadge(logo: nil, monogram: Self.initials(pair.away), diameter: diameter)
            }
        } else {
            let channelLogo = fixture.broadcasts.lazy.compactMap(\.channel.logoURL).first
            SportsArtworkBadge(logo: channelLogo, symbol: fixture.sport.symbol, diameter: diameter)
        }
    }

    private func divider(diameter: CGFloat) -> some View {
        Capsule().fill(.white.opacity(0.32)).frame(width: 1, height: diameter * 0.34)
    }

    private static func monogram(_ team: SportsTeam) -> String {
        let abbreviation = team.abbreviation.filter { $0.isLetter || $0.isNumber }
        return abbreviation.isEmpty ? initials(team.name) : String(abbreviation.prefix(4)).uppercased()
    }

    private static func initials(_ title: String) -> String {
        let words = title.split { !$0.isLetter && !$0.isNumber }
        if words.count > 1 { return String(words.prefix(3).compactMap(\.first)).uppercased() }
        return String(words.first?.prefix(3) ?? "").uppercased()
    }
}

private struct SportsArtworkBadge: View {
    let logo: URL?
    var monogram: String? = nil
    var symbol: String? = nil
    let diameter: CGFloat

    @State private var failedURL: URL?

    var body: some View {
        Circle()
            .fill(Color(white: 0.42, opacity: 0.35))
            .overlay { Circle().strokeBorder(Color(white: 0.8, opacity: 0.22), lineWidth: 1) }
            .frame(width: diameter, height: diameter)
            .overlay { content.foregroundStyle(Color(white: 0.9)) }
    }

    @ViewBuilder private var content: some View {
        if let logo, logo != failedURL {
            let side = (diameter * 0.68).rounded()
            RemoteImage(
                url: logo, size: CGSize(width: side, height: side), contentMode: .fit,
                placeholderSeed: "sports-emblem", showsPlaceholder: false,
                onLoadFailure: { failedURL = logo }
            )
        } else if let monogram, !monogram.isEmpty {
            Text(monogram)
                .font(.system(size: diameter * 0.30, weight: .semibold, design: .monospaced))
                .tracking(0.2)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.43, weight: .medium))
        }
    }
}
