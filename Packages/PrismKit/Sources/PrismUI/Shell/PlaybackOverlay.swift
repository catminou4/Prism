import PrismDesign
import SwiftUI

/// Window-level presenter for the playback sheet. Unlike `.sheet`, it can open the sheet out of
/// the card that was clicked (Apple TV zoom) and fold it back into that card when closing.
///
/// The entrance is a shared-element transition: the card's artwork flies into the sheet's hero
/// band while the panel grows from the card behind it, and the sheet content is revealed inside
/// the panel and fades in on top. The flight uses a small decode of the artwork the card already
/// downloaded, so it can start almost immediately; the sheet's full-resolution hero loads
/// underneath it. The zoom starts once that decode and the synopsis are ready, or after a short
/// fallback delay.
@Observable
final class PlaybackOverlayModel {
    struct Presentation: Identifiable {
        let id = UUID()
        /// Frame of the originating card in global coordinates; `nil` zooms from the centre.
        let source: CGRect?
        let content: (CGSize) -> AnyView
    }

    private(set) var presentation: Presentation?
    /// Animated 0 → 1 once the sheet is ready, back to 0 before removal.
    fileprivate(set) var expanded = false
    /// The card's artwork, decoded small, for the flight into the hero band.
    fileprivate(set) var flightArtwork: CGImage?
    @ObservationIgnored private var closingID: UUID?
    @ObservationIgnored private var openedID: UUID?
    @ObservationIgnored private var artworkPending = false
    @ObservationIgnored private var contentPending = false

    /// Critically damped: decelerates into place without overshooting (no settle wobble).
    static let openAnimation = Animation.smooth(duration: 0.52)
    static let closeAnimation = Animation.smooth(duration: 0.36)
    /// Longest the zoom waits before starting anyway.
    static let preparationBudget = Duration.milliseconds(160)
    /// Small enough to decode in a few milliseconds from the card rendition already on disk.
    private static let flightPixelSize = CGSize(width: 640, height: 360)

    var isPresented: Bool { presentation != nil }

    func present(from source: CGRect?, artwork: URL? = nil, content: @escaping (CGSize) -> some View) {
        closingID = nil
        openedID = nil
        expanded = false
        let presentation = Presentation(source: source) { AnyView(content($0)) }
        self.presentation = presentation
        contentPending = true
        guard source != nil, let artwork else {
            flightArtwork = nil
            artworkPending = false
            return
        }
        if let cached = ImagePipeline.shared.cachedImage(for: artwork, pixelSize: Self.flightPixelSize) {
            flightArtwork = cached
            artworkPending = false
            return
        }
        flightArtwork = nil
        artworkPending = true
        let id = presentation.id
        Task { [weak self] in
            let image = await ImagePipeline.shared.image(for: artwork, pixelSize: Self.flightPixelSize)
            guard let self, self.presentation?.id == id else { return }
            // Too late to fly once the zoom has started: the sheet's own hero takes over.
            if openedID != id { flightArtwork = image }
            artworkPending = false
            openIfReady(id)
        }
    }

    /// Called by the presented sheet once its first frame is final.
    func contentReady() {
        guard let id = presentation?.id else { return }
        contentPending = false
        openIfReady(id)
    }

    func dismiss() {
        guard let id = presentation?.id, closingID != id else { return }
        closingID = id
        guard openedID == id else {
            // Closed before the zoom started: nothing on screen to animate back.
            presentation = nil
            closingID = nil
            flightArtwork = nil
            return
        }
        withAnimation(Self.closeAnimation) {
            expanded = false
        } completion: { [weak self] in
            guard let self, closingID == id, presentation?.id == id else { return }
            presentation = nil
            closingID = nil
            flightArtwork = nil
        }
    }

    private func openIfReady(_ id: UUID) {
        if !artworkPending, !contentPending { open(id) }
    }

    fileprivate func open(_ id: UUID) {
        guard presentation?.id == id, closingID == nil, openedID != id else { return }
        openedID = id
        withAnimation(Self.openAnimation) { expanded = true }
    }
}

extension EnvironmentValues {
    /// Set by `LibraryShell`; pages present the playback sheet through it when available.
    @Entry var playbackOverlay: PlaybackOverlayModel? = nil
    /// The overlay hosting the current view (the playback sheet), if any — used to close it.
    @Entry var hostingPlaybackOverlay: PlaybackOverlayModel? = nil
}

/// Dim layer + transitioning sheet, laid over the whole split view.
struct PlaybackOverlayHost: View {
    let model: PlaybackOverlayModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            if let presentation = model.presentation {
                let origin = proxy.frame(in: .global).origin
                let size = TitlePlaybackSheet.size(for: proxy.size)
                let target = CGRect(
                    x: ((proxy.size.width - size.width) / 2).rounded(),
                    y: ((proxy.size.height - size.height) / 2).rounded(),
                    width: size.width, height: size.height
                )
                ZStack(alignment: .topLeading) {
                    Color.black
                        .opacity(model.expanded ? 0.42 : 0)
                        .contentShape(.rect)
                        .onTapGesture { model.dismiss() }
                        .accessibilityHidden(true)
                    presentation.content(proxy.size)
                        .environment(\.hostingPlaybackOverlay, model)
                        .modifier(SheetTransition(
                            progress: model.expanded ? 1 : 0,
                            source: presentation.source?.offsetBy(dx: -origin.x, dy: -origin.y),
                            target: target,
                            heroHeight: TitlePlaybackSheet.heroHeight(for: size),
                            artwork: model.flightArtwork,
                            fadeOnly: reduceMotion
                        ))
                        .accessibilityAddTraits(.isModal)
                }
                .id(presentation.id)
                .task(id: presentation.id) {
                    try? await Task.sleep(for: PlaybackOverlayModel.preparationBudget)
                    if !Task.isCancelled { model.open(presentation.id) }
                }
            }
        }
        .allowsHitTesting(model.isPresented)
    }
}

/// Draws, for one `progress` value (so every part stays in sync and the animation reverses):
/// 1. a panel growing from the card to the sheet frame, its colour going from the card's dark
///    fill to the page background, with a window-space shadow;
/// 2. the card artwork flying from the card's image area into the hero band;
/// 3. the sheet itself, laid out once at its final position, revealed inside the panel and faded
///    in on top of the flying artwork (same picture, so the hand-off is invisible).
///
/// Built for 120 Hz: every crop is a layout frame plus a rounded-rect clip (no offscreen mask
/// pass), the sheet is never scaled (text and glass render once, at their final size) and only
/// moves by offsets; at rest the sheet is just clipped to its corners.
private struct SheetTransition: ViewModifier, Animatable {
    var progress: CGFloat
    let source: CGRect?
    let target: CGRect
    let heroHeight: CGFloat
    let artwork: CGImage?
    /// Reduce Motion: no zoom, only a cross-fade.
    let fadeOnly: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let sheetRadius: CGFloat = 26
    private static let cardFill = Color(white: 0.10)

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let card = fadeOnly ? nil : source
        let start = fadeOnly ? target : card ?? target.insetBy(dx: target.width * 0.025, dy: target.height * 0.025)
        let panel = Self.lerp(start, target, p)
        let radius = Self.lerp(card == nil ? Self.sheetRadius : PrismMetrics.wideRadius, Self.sheetRadius, p)
        let flies = card != nil && artwork != nil
        // From a card the panel (and artwork) are there from the first frame and the sheet fades
        // in over them; from nowhere everything fades in together.
        let panelOpacity = card == nil ? p : 1
        let reveal = card == nil ? p : Self.smoothstep(flies ? 0.58 : 0.05, flies ? 0.97 : 0.55, p)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .topLeading) {
            ZStack {
                PrismColors.pageBackground
                if card != nil {
                    Self.cardFill.opacity(1 - Self.smoothstep(0.05, 0.6, p))
                }
            }
            .frame(width: panel.width, height: panel.height)
            .clipShape(shape)
            .background { shape.fill(.black).shadow(color: .black.opacity(0.3 * p), radius: 30, y: 14) }
            .offset(x: panel.minX, y: panel.minY)
            .opacity(panelOpacity)
            .allowsHitTesting(false)

            if let card, let artwork {
                flight(artwork, from: card, progress: p, radius: radius)
            }

            content
                .frame(width: target.width, height: target.height, alignment: .topLeading)
                .offset(x: target.minX - panel.minX, y: target.minY - panel.minY)
                .frame(width: panel.width, height: panel.height, alignment: .topLeading)
                .clipShape(shape)
                .offset(x: panel.minX, y: panel.minY)
                .opacity(reveal)
        }
    }

    /// The card artwork, aspect-filled and top-aligned like `HeroBackdrop`, with the hero's
    /// leading scrim fading in so it matches the real hero when the sheet fades in over it.
    private func flight(_ artwork: CGImage, from card: CGRect, progress p: CGFloat, radius: CGFloat) -> some View {
        let from = CGRect(
            x: card.minX, y: card.minY,
            width: card.width, height: min(card.height, (card.width / PrismMetrics.wideAspectRatio).rounded())
        )
        let to = CGRect(x: target.minX, y: target.minY, width: target.width, height: heroHeight)
        let frame = Self.lerp(from, to, p)
        let bottomRadius = Self.lerp(PrismMetrics.wideRadius, 0, p)
        return Image(decorative: artwork, scale: 1)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fill)
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.75), location: 0),
                        .init(color: .black.opacity(0.3), location: 0.35),
                        .init(color: .clear, location: 0.62),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .opacity(p)
            }
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: bottomRadius,
                bottomTrailingRadius: bottomRadius, topTrailingRadius: radius, style: .continuous
            ))
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(
            x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
            width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t)
        )
    }

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
