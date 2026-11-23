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
/// a pure transform (120 Hz friendly). Pauses under Reduce Motion, while the window is
/// occluded or the app inactive — the drift clock freezes in place, so resuming never jumps
/// and never pays a re-raster while hidden.
public struct PosterWall: View {
    private let tileStorage: PosterWallTileStorage
    private let tileWidth: CGFloat
    private let spacing: CGFloat
    private let angle: Angle
    private let speed: CGFloat
    private let vignette: Double
    private let isAnimating: Bool
    private let startTime: Double
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var size: CGSize = .zero
    @State private var isWindowVisible = true
    @State private var clock: DriftClock

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
        let resolvedTiles = tiles.isEmpty ? [PosterWallTile].procedural(count: 30) : tiles
        tileStorage = PosterWallTileStorage(resolvedTiles)
        self.tileWidth = tileWidth
        self.spacing = spacing
        self.angle = angle
        self.speed = speed
        self.vignette = vignette
        self.isAnimating = isAnimating
        self.startTime = startTime
        _clock = State(initialValue: DriftClock(travel: CGFloat(startTime) * speed))
    }

    private var pitch: CGSize {
        CGSize(width: tileWidth + spacing, height: tileWidth / PrismMetrics.posterAspectRatio + spacing)
    }

    /// Grid dimensions covering the rotated viewport. Only the width margin is slimmed:
    /// drift and stagger are vertical, so extra columns were pure raster cost, while the
    /// row count must keep its headroom or the bottom edge shows during the row shift.
    private var gridSize: (columns: Int, rows: Int) {
        let radians = abs(angle.radians)
        let coverWidth = size.width * cos(radians) + size.height * sin(radians)
        let coverHeight = size.width * sin(radians) + size.height * cos(radians)
        let columns = Int((coverWidth * 1.05) / pitch.width) + 2
        let rows = Int((coverHeight * 1.2) / pitch.height) + 3
        return (columns, rows)
    }

    /// True while the wall may drift: animating, in a visible window, app active, no Reduce Motion.
    private var isPaused: Bool { !isAnimating || reduceMotion || !appearsActive || !isWindowVisible }

    public var body: some View {
        let paused = isPaused
        // The drift is slow (a few points per second): 60 Hz is plenty and halves the
        // per-frame timeline work on ProMotion displays.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: paused)) { context in
            driftingWall(at: context.date)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .overlay { vignetteOverlay.allowsHitTesting(false) }
        .clipped()
        .background {
            WindowOcclusionReader(isVisible: $isWindowVisible)
        }
        .background(.black)
        .accessibilityHidden(true)
    }

    /// Grid content for one timeline tick. Kept out of the `TimelineView` builder so the
    /// clock mutation stays a plain statement instead of a builder expression.
    private func driftingWall(at date: Date) -> some View {
        if !isPaused { clock.advance(to: date, speed: speed) }
        let travel = clock.travel
        let rowShift = Int(floor(travel / pitch.height))
        let fraction = travel - CGFloat(rowShift) * pitch.height
        let grid = gridSize
        return PosterWallGrid(
            tileStorage: tileStorage, columns: grid.columns, rows: grid.rows, rowShift: rowShift,
            tileWidth: tileWidth, spacing: spacing
        )
        .equatable()
        .offset(y: -fraction)
        .frame(width: size.width, height: size.height)
        .rotation3DEffect(.degrees(12), axis: (x: 0.2, y: 1, z: 0), perspective: 0.5)
        .rotationEffect(angle)
    }

    private var vignetteOverlay: some View {
        ZStack {
            Color.black.opacity(0.5 * vignette)
            RadialGradient(colors: [.clear, .black.opacity(0.8 * vignette)], center: .center, startRadius: 80, endRadius: max(size.width, size.height) * 0.7)
            LinearGradient(colors: [.black.opacity(0.3 * vignette), .clear, .black.opacity(0.85 * vignette)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Drift accumulator for `PosterWall`. Advancing only while unpaused freezes the wall
/// exactly in place — pausing costs no re-raster and resuming never jumps; long gaps
/// (occlusion, hitches) are clamped to one frame so the wall cannot leap forward.
private final class DriftClock {
    var travel: CGFloat
    private var lastDate: Date?

    init(travel: CGFloat) {
        self.travel = travel
    }

    func advance(to date: Date, speed: CGFloat) {
        if let lastDate {
            let delta = date.timeIntervalSince(lastDate)
            travel += CGFloat(min(max(delta, 0), 0.1)) * speed
        }
        lastDate = date
    }
}

/// Reference box for a `PosterWall`'s tile list: the grid struct is rebuilt every timeline
/// tick and `Equatable` compares it — identity is O(1) where comparing ~60 tiles per frame was not.
private final class PosterWallTileStorage {
    let tiles: [PosterWallTile]
    init(_ tiles: [PosterWallTile]) { self.tiles = tiles }
}

/// Static grid; equatable so it only re-renders (and re-rasterises) when a row scrolls by.
private struct PosterWallGrid: View, Equatable {
    let tileStorage: PosterWallTileStorage
    let columns: Int
    let rows: Int
    let rowShift: Int
    let tileWidth: CGFloat
    let spacing: CGFloat

    nonisolated static func == (lhs: PosterWallGrid, rhs: PosterWallGrid) -> Bool {
        guard lhs.rowShift == rhs.rowShift, lhs.columns == rhs.columns, lhs.rows == rhs.rows,
              lhs.tileWidth == rhs.tileWidth, lhs.spacing == rhs.spacing else { return false }
        // Same wall → same storage → O(1). A recreated `PosterWall` gets a fresh storage:
        // fall back to the value compare so equal tiles still skip the re-raster.
        return lhs.tileStorage === rhs.tileStorage || lhs.tileStorage.tiles == rhs.tileStorage.tiles
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
        let tiles = tileStorage.tiles
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
        .clipShape(.rect(cornerRadius: PrismMetrics.wideRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PrismMetrics.wideRadius, style: .continuous).strokeBorder(.white.opacity(0.08), lineWidth: 1)
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
