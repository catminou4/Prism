import PrismDesign
import SwiftUI

/// Window-level presenter for the playback sheet. Unlike `.sheet`, it can grow the sheet out of
/// the card that opened it (Apple TV zoom) and shrink it back into that card when closing.
///
/// Presentation happens in two steps so the zoom never competes with first-time work: the sheet
/// is inserted invisibly, prepares itself (hero artwork decoded, synopsis resolved) and calls
/// `contentReady()`; only then does the 0 → 1 animation start. A short fallback timer starts it
/// anyway if preparation is slow (offline artwork…).
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
    @ObservationIgnored private var closingID: UUID?
    @ObservationIgnored private var openedID: UUID?

    /// Critically damped: decelerates into place without overshooting (no settle wobble).
    static let openAnimation = Animation.smooth(duration: 0.46)
    static let closeAnimation = Animation.smooth(duration: 0.34)
    /// Longest the zoom waits for the sheet to prepare itself.
    static let preparationBudget = Duration.milliseconds(260)

    var isPresented: Bool { presentation != nil }

    func present(from source: CGRect?, content: @escaping (CGSize) -> some View) {
        closingID = nil
        openedID = nil
        expanded = false
        presentation = Presentation(source: source) { AnyView(content($0)) }
    }

    /// Called by the presented sheet once its first frame is final.
    func contentReady() {
        guard let id = presentation?.id else { return }
        open(id)
    }

    func dismiss() {
        guard let id = presentation?.id, closingID != id else { return }
        closingID = id
        guard openedID == id else {
            // Closed before the zoom started: nothing on screen to animate back.
            presentation = nil
            closingID = nil
            return
        }
        withAnimation(Self.closeAnimation) {
            expanded = false
        } completion: { [weak self] in
            guard let self, closingID == id, presentation?.id == id else { return }
            presentation = nil
            closingID = nil
        }
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

/// Dim layer + zooming sheet, laid over the whole split view.
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
                let source = presentation.source?.offsetBy(dx: -origin.x, dy: -origin.y)
                ZStack(alignment: .topLeading) {
                    Color.black
                        .opacity(model.expanded ? 0.42 : 0)
                        .contentShape(.rect)
                        .onTapGesture { model.dismiss() }
                        .accessibilityHidden(true)
                    presentation.content(proxy.size)
                        .environment(\.hostingPlaybackOverlay, model)
                        .modifier(ZoomFromSource(
                            progress: model.expanded ? 1 : 0, source: source, target: target, fadeOnly: reduceMotion
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

/// Places a `target`-sized view so that at `progress` 0 it exactly covers `source` (scaled to
/// fill it, cropped around the horizontal centre from the top, with the card's corner radius)
/// and at 1 fills `target`.
///
/// Built for 120 Hz: the crop is a layout frame plus a rounded-rect clip (a corner radius on the
/// layer, not an offscreen mask pass), the content is only scaled and translated, and the shadow
/// is drawn by a separate plate in window space at a constant radius rather than blurred at the
/// sheet's full, unscaled size.
private struct ZoomFromSource: ViewModifier, Animatable {
    var progress: CGFloat
    let source: CGRect?
    let target: CGRect
    /// Reduce Motion: no zoom, only a cross-fade.
    let fadeOnly: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    private static let sheetRadius: CGFloat = 26

    func body(content: Content) -> some View {
        let p = min(max(progress, 0), 1)
        let fromCard = source != nil && !fadeOnly
        let start = fadeOnly ? target : source ?? target.insetBy(dx: target.width * 0.03, dy: target.height * 0.03)
        let rect = CGRect(
            x: lerp(start.minX, target.minX, p), y: lerp(start.minY, target.minY, p),
            width: lerp(start.width, target.width, p), height: lerp(start.height, target.height, p)
        )
        let scale = max(rect.width / target.width, rect.height / target.height, 0.01)
        let cropped = CGSize(width: min(target.width, rect.width / scale), height: min(target.height, rect.height / scale))
        let visibleRadius = lerp(fromCard ? PrismMetrics.wideRadius : Self.sheetRadius, Self.sheetRadius, p)
        let plate = RoundedRectangle(cornerRadius: visibleRadius, style: .continuous)
        // From a card the artwork is already on screen: show it almost at once. Otherwise fade.
        let opacity = fromCard ? min(1, p * 8) : p
        ZStack(alignment: .topLeading) {
            plate
                .fill(PrismColors.pageBackground)
                .frame(width: rect.width, height: rect.height)
                .shadow(color: .black.opacity(0.3 * p), radius: 30, y: 14)
                .offset(x: rect.minX, y: rect.minY)
                .opacity(opacity)
                .allowsHitTesting(false)
            content
                .frame(width: target.width, height: target.height, alignment: .topLeading)
                .frame(width: cropped.width, height: cropped.height, alignment: .top)
                .clipShape(.rect(cornerRadius: visibleRadius / scale, style: .continuous))
                .scaleEffect(scale, anchor: .topLeading)
                .offset(x: rect.minX, y: rect.minY)
                .opacity(opacity)
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
