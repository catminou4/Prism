import SwiftUI

/// One tile of the poster wall.
nonisolated public struct PosterWallTile: Identifiable, Hashable, Sendable {
    public let id: Int
    public var title: String
    public var imageURL: URL?

    public init(id: Int, title: String, imageURL: URL? = nil) {
        self.id = id
        self.title = title
        self.imageURL = imageURL
    }
}

nonisolated extension Array where Element == PosterWallTile {
    /// Procedural posters with French fake titles.
    public static func procedural(count: Int = 60) -> [PosterWallTile] {
        let titles = [
            "Lumière Noire", "L'Horizon", "Nocturne", "Les Échos", "Orbite", "Le Dernier Été", "Mirage", "Fragments",
            "La Traversée", "Néon", "Saison Rouge", "Atlas", "Les Veilleurs", "Sirocco", "Vertige", "L'Archipel",
            "Polaris", "Les Ombres", "Cavale", "Le Phare", "Solstice", "Brume", "Hors Champ", "Mistral",
            "Les Indomptés", "Zénith", "Kilomètre Zéro", "Marée Haute", "Le Silence", "Odyssée",
        ]
        return (0..<Swift.max(count, 1)).map { PosterWallTile(id: $0, title: titles[$0 % titles.count]) }
    }
}

/// The tilted, endlessly drifting poster mosaic of the Apple TV tab / onboarding.
///
/// A single `TimelineView` offset moves a static, rasterised grid (`drawingGroup`) along its
/// columns; the grid re-renders only when a whole row has scrolled by, so the animation is
/// a pure transform (120 Hz friendly). Pauses under Reduce Motion.
public struct PosterWall: View {
    private let tiles: [PosterWallTile]
    private let tileWidth: CGFloat
    private let spacing: CGFloat
    private let angle: Angle
    private let speed: CGFloat
    private let vignette: Double
    private let isAnimating: Bool
    private let startTime: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero
    @State private var epoch = Date()

    /// - Parameters:
    ///   - speed: Drift speed in points per second.
    ///   - vignette: Strength (0…1) of the dark overlay used to put content on top.
    ///   - startTime: Initial drift time (seconds), useful for static snapshots.
    public init(
        tiles: [PosterWallTile] = .procedural(count: 60),
        tileWidth: CGFloat = 150,
        spacing: CGFloat = 18,
        angle: Angle = .degrees(-12),
        speed: CGFloat = 12,
        vignette: Double = 0.6,
        isAnimating: Bool = true,
        startTime: Double = 0
    ) {
        self.tiles = tiles.isEmpty ? .procedural(count: 30) : tiles
        self.tileWidth = tileWidth
        self.spacing = spacing
        self.angle = angle
        self.speed = speed
        self.vignette = vignette
        self.isAnimating = isAnimating
        self.startTime = startTime
    }

    private var pitch: CGSize {
        CGSize(width: tileWidth + spacing, height: tileWidth / PrismMetrics.posterAspectRatio + spacing)
    }

    /// Grid dimensions covering the rotated viewport.
    private var gridSize: (columns: Int, rows: Int) {
        let radians = abs(angle.radians)
        let coverWidth = size.width * cos(radians) + size.height * sin(radians)
        let coverHeight = size.width * sin(radians) + size.height * cos(radians)
        let columns = Int((coverWidth * 1.25) / pitch.width) + 2
        let rows = Int((coverHeight * 1.2) / pitch.height) + 3
        return (columns, rows)
    }

    public var body: some View {
        let paused = !isAnimating || reduceMotion
        TimelineView(.animation(minimumInterval: nil, paused: paused)) { context in
            let elapsed = startTime + (paused ? 0 : context.date.timeIntervalSince(epoch))
            let travel = CGFloat(elapsed) * speed
            let rowShift = Int(floor(travel / pitch.height))
            let fraction = travel - CGFloat(rowShift) * pitch.height
            let grid = gridSize
            PosterWallGrid(
                tiles: tiles, columns: grid.columns, rows: grid.rows, rowShift: rowShift,
                tileWidth: tileWidth, spacing: spacing
            )
            .equatable()
            .offset(y: -fraction)
            .frame(width: size.width, height: size.height)
            .rotation3DEffect(.degrees(12), axis: (x: 0.2, y: 1, z: 0), perspective: 0.5)
            .rotationEffect(angle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .overlay { vignetteOverlay.allowsHitTesting(false) }
        .clipped()
        .background(.black)
        .accessibilityHidden(true)
    }

    private var vignetteOverlay: some View {
        ZStack {
            Color.black.opacity(0.5 * vignette)
            RadialGradient(colors: [.clear, .black.opacity(0.8 * vignette)], center: .center, startRadius: 80, endRadius: max(size.width, size.height) * 0.7)
            LinearGradient(colors: [.black.opacity(0.3 * vignette), .clear, .black.opacity(0.85 * vignette)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Static grid; equatable so it only re-renders (and re-rasterises) when a row scrolls by.
private struct PosterWallGrid: View, Equatable {
    let tiles: [PosterWallTile]
    let columns: Int
    let rows: Int
    let rowShift: Int
    let tileWidth: CGFloat
    let spacing: CGFloat

    nonisolated static func == (lhs: PosterWallGrid, rhs: PosterWallGrid) -> Bool {
        lhs.rowShift == rhs.rowShift && lhs.columns == rhs.columns && lhs.rows == rhs.rows
            && lhs.tileWidth == rhs.tileWidth && lhs.tiles == rhs.tiles
    }

    var body: some View {
        let tileHeight = tileWidth / PrismMetrics.posterAspectRatio
        let pitchY = tileHeight + spacing
        HStack(alignment: .top, spacing: spacing) {
            ForEach(0..<columns, id: \.self) { column in
                VStack(spacing: spacing) {
                    ForEach(0..<rows, id: \.self) { row in
                        let tile = tile(column: column, row: row + rowShift)
                        PosterWallCell(tile: tile, size: CGSize(width: tileWidth, height: tileHeight))
                    }
                }
                // Staggered columns like the Apple TV wall.
                .offset(y: column.isMultiple(of: 2) ? 0 : -pitchY * 0.5)
            }
        }
        .fixedSize()
        .drawingGroup()
    }

    /// Deterministic tile for an absolute grid position (rows wrap through the tile list).
    private func tile(column: Int, row: Int) -> PosterWallTile {
        let count = tiles.count
        let index = ((column * 7 + row * 3) % count + count) % count
        return tiles[index]
    }
}

private struct PosterWallCell: View {
    let tile: PosterWallTile
    let size: CGSize

    var body: some View {
        Group {
            if let url = tile.imageURL {
                RemoteImage(url: url, size: size, placeholderSeed: tile.title, placeholderTitle: tile.title)
            } else {
                ProceduralPoster(seed: "\(tile.id)-\(tile.title)", title: tile.title)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(.rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
    }
}

#Preview("PosterWall") {
    PosterWall()
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 12) {
                PrismLogoLockup(size: 30, wordmarkColor: .white)
                Text("Toutes vos chaînes, films et séries.")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(40)
        }
        .frame(width: 1000, height: 600)
}
