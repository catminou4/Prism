import CoreGraphics

/// Layout metrics measured on the Apple TV app for Mac (macOS 26/27, 2× captures).
///
/// Values are in points. Where the Apple TV app sizes cards to fill the visible width
/// (it always shows a whole number of columns), shelves use the `*MinWidth` values to
/// compute the column count and fall back to the fixed widths elsewhere.
nonisolated public enum PrismMetrics {
    // MARK: Page
    /// Leading/trailing content margin of every page.
    public static let contentMargin: CGFloat = 40
    /// Vertical gap between two shelves (card bottom → next header).
    public static let shelfSpacing: CGFloat = 36
    /// Gap between a shelf header and its cards.
    public static let shelfHeaderSpacing: CGFloat = 12
    /// Horizontal gap between two cards of a shelf.
    public static let cardSpacing: CGFloat = 20
    /// Vertical gap between rows of a grid.
    public static let gridRowSpacing: CGFloat = 28

    // MARK: Cards
    /// Poster (2:3) default width.
    public static let posterWidth: CGFloat = 150
    /// Minimum poster width used to compute shelf columns (Apple: 6 columns at 920 pt).
    public static let posterMinWidth: CGFloat = 130
    public static let posterAspectRatio: CGFloat = 2.0 / 3.0
    /// Two lines of poster metadata, including the gap below the art.
    public static let posterCaptionHeight: CGFloat = 40
    /// Wide card (16:9 artwork + caption band) default width.
    public static let wideCardWidth: CGFloat = 260
    /// Minimum wide-card width used to compute shelf columns (Apple: 4 columns at 920 pt).
    public static let wideCardMinWidth: CGFloat = 200
    public static let wideAspectRatio: CGFloat = 16.0 / 9.0
    /// Height of the blurred caption band under a wide card's 16:9 artwork.
    public static let wideCardCaptionBand: CGFloat = 30
    /// Episode card default width (16:9 still + text block).
    public static let episodeCardWidth: CGFloat = 280
    /// Height of the text block under an episode still.
    public static let episodeTextBlock: CGFloat = 104
    /// Person portrait diameter.
    public static let personDiameter: CGFloat = 96
    /// Category (genre) tile default width.
    public static let categoryTileWidth: CGFloat = 150
    /// Channel tile default width (16:9).
    public static let channelTileWidth: CGFloat = 260

    // MARK: Radii
    public static let wideRadius: CGFloat = 12
    public static let posterRadius = wideRadius
    public static let tileRadius = wideRadius
    public static let heroRadius: CGFloat = 18
    public static let panelRadius: CGFloat = 14
    public static let listRowRadius: CGFloat = 10
    public static let smallArtworkRadius: CGFloat = 8
    public static let sourceCardRadius = panelRadius
    public static let badgeRadius: CGFloat = 3

    // MARK: Badges
    public static let badgeHeight: CGFloat = 12
    public static let badgeHorizontalPadding: CGFloat = 3.5

    // MARK: Buttons
    /// Primary white capsule height (measured: 36 pt in a 1220 pt window).
    public static let primaryButtonHeight: CGFloat = 36
    /// Large primary capsule (onboarding / empty states).
    public static let largeButtonHeight: CGFloat = 40
    public static let primaryButtonHorizontalPadding: CGFloat = 24
    /// Secondary hero circle (`+` Ma liste) diameter.
    public static let circleButtonSize: CGFloat = 36
    /// Toolbar glass circles (back, mute, fullscreen, share).
    public static let toolbarButtonSize: CGFloat = 36
    /// Small glass circles (compact toolbars, player side buttons).
    public static let compactButtonSize: CGFloat = 32
    /// Shelf paging chevrons.
    public static let shelfChevronSize: CGFloat = 28
    /// Glass capsule (source picker / chips) height.
    public static let capsuleHeight: CGFloat = 32
    /// Gap between hero buttons.
    public static let heroButtonSpacing: CGFloat = 12

    // MARK: Hero
    /// Bottom padding of the hero content block.
    public static let heroBottomPadding: CGFloat = 40
    /// Maximum width of the hero text block.
    public static let heroTextMaxWidth: CGFloat = 280
    public static let titleLogoMaxHeight: CGFloat = 120
    public static let titleLogoMaxWidth: CGFloat = 420
    /// Home hero height ≈ 55 % of the window (clamped).
    public static func homeHeroHeight(for windowHeight: CGFloat) -> CGFloat {
        min(max(windowHeight * 0.55, 380), 620)
    }
    /// Detail hero height ≈ 78 % of the window (clamped).
    public static func detailHeroHeight(for windowHeight: CGFloat) -> CGFloat {
        min(max(windowHeight * 0.78, 460), 760)
    }

    // MARK: Shell
    public static let sidebarWidth: CGFloat = 220

    /// Column width that fits a whole number of columns of at least `minWidth` in `available`.
    public static func columnWidth(available: CGFloat, minWidth: CGFloat, spacing: CGFloat = cardSpacing) -> CGFloat {
        guard available > 0, minWidth > 0 else { return minWidth }
        let count = max(1, Int((available + spacing) / (minWidth + spacing)))
        return ((available - spacing * CGFloat(count - 1)) / CGFloat(count)).rounded(.down)
    }
}
