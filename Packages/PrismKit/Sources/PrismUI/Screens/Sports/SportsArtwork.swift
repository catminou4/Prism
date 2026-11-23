import Foundation
import PrismCore
import PrismData
import PrismDesign
import SwiftUI

/// Sports artwork with a team or channel fallback at the same display size.
struct SportsArtwork: View {
    enum Placement { case card, feature }

    let fixture: SportsFixture
    let size: CGSize
    var placement: Placement = .card

    @State private var failedURLs: Set<URL> = []

    private var artworkURL: URL? {
        if let official = fixture.event?.artworkURL, !failedURLs.contains(official) { return official }
        return fixture.broadcasts.lazy.compactMap(\.program.iconURL).first { !failedURLs.contains($0) }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: palette, startPoint: .bottomLeading, endPoint: .topTrailing)
            RadialGradient(
                colors: [.white.opacity(0.16), .clear], center: .init(x: 0.76, y: 0.27),
                startRadius: 0, endRadius: max(1, size.width * 0.48)
            )

            content
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var palette: [Color] {
        switch fixture.sport {
        case .football: [Color(red: 0.04, green: 0.14, blue: 0.23), Color(red: 0.10, green: 0.45, blue: 0.48)]
        case .basketball: [Color(red: 0.20, green: 0.06, blue: 0.13), Color(red: 0.61, green: 0.28, blue: 0.13)]
        case .boxing: [Color(red: 0.14, green: 0.09, blue: 0.28), Color(red: 0.42, green: 0.27, blue: 0.66)]
        }
    }

    @ViewBuilder private var content: some View {
        if let artworkURL {
            RemoteImage(
                url: artworkURL, size: size, placeholderSeed: fixture.id, showsPlaceholder: false,
                onLoadFailure: { failedURLs.insert(artworkURL) }
            )
        } else {
            let isFeature = placement == .feature
            let center = CGPoint(x: size.width * (isFeature ? 0.755 : 0.5), y: size.height * (isFeature ? 0.5 : 0.55))
            Ellipse()
                .strokeBorder(.white.opacity(0.09), lineWidth: 1)
                .frame(width: size.width * 0.52, height: size.height * 0.86)
                .rotationEffect(.degrees(-27))
                .position(center)
            emblems(diameter: min(isFeature ? 112 : 88, size.height * (isFeature ? 0.34 : 0.40)))
                .position(center)
        }
    }

    @ViewBuilder private func emblems(diameter: CGFloat) -> some View {
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
            .fill(.white.opacity(0.13))
            .overlay { Circle().strokeBorder(.white.opacity(0.27), lineWidth: 1) }
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
                .font(.system(size: diameter * 0.30, weight: .bold, design: .rounded))
                .tracking(0.2)
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.43, weight: .medium))
        }
    }
}
