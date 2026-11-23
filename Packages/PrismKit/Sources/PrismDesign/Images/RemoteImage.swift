import CoreGraphics
import SwiftUI

/// Downsampled remote artwork with a deterministic placeholder and a 0.25 s cross-fade.
///
/// - Loads through `ImagePipeline.shared` in `.task(id:)`, so loading stops when the view
///   leaves the screen (lazy stacks) and restarts if it comes back.
/// - Pass `size` whenever it is known (cards); `nil` measures the proposed size once.
/// - The view always takes the proposed/explicit size: image loading never changes layout.
public struct RemoteImage: View {
    private let url: URL?
    private let size: CGSize?
    private let contentMode: ContentMode
    private let alignment: Alignment
    private let decodingFitting: ImagePipeline.Fitting?
    private let placeholderSeed: String
    private let placeholderTitle: String?
    private let placeholderStyle: PlaceholderArtwork.TitleStyle
    private let blurRadius: CGFloat
    private let showsPlaceholder: Bool
    private let progressive: Bool
    private let onLoadFailure: (() -> Void)?
    private var blurSourceSize: CGSize?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismScrollActivity) private var scrollActivity

    private var imageFade: Animation? {
        scrollActivity?.isScrolling == true ? nil : PrismMotion.respecting(reduceMotion, PrismMotion.imageFade)
    }
    @State private var loaded: Loaded?
    @State private var measuredSize: CGSize = .zero

    public init(
        url: URL?,
        size: CGSize? = nil,
        contentMode: ContentMode = .fill,
        alignment: Alignment = .center,
        fitting: ImagePipeline.Fitting? = nil,
        placeholderSeed: String,
        placeholderTitle: String? = nil,
        placeholderStyle: PlaceholderArtwork.TitleStyle = .title,
        blurRadius: CGFloat = 0,
        showsPlaceholder: Bool = true,
        progressive: Bool = false,
        onLoadFailure: (() -> Void)? = nil
    ) {
        self.url = url
        self.size = size
        self.contentMode = contentMode
        self.alignment = alignment
        self.decodingFitting = fitting
        self.placeholderSeed = placeholderSeed
        self.placeholderTitle = placeholderTitle
        self.placeholderStyle = placeholderStyle
        self.blurRadius = blurRadius
        self.showsPlaceholder = showsPlaceholder
        self.progressive = progressive
        self.onLoadFailure = onLoadFailure
    }

    private struct Loaded: Equatable {
        let key: ImagePipeline.Key
        let image: CGImage
        static func == (lhs: Loaded, rhs: Loaded) -> Bool { lhs.key == rhs.key && lhs.image === rhs.image }
    }

    private var loadKey: ImagePipeline.Key? {
        guard let url else { return nil }
        // Blurs have a fixed decode size, regardless of the slot they fill.
        let points = blurRadius > 0 ? CGSize(width: 1, height: 1) : (size ?? measuredSize)
        let pixels = Self.pixelSize(forPointSize: points, scale: displayScale)
        return ImagePipeline.key(url: url, pixelSize: pixels, fitting: fitting, blurRadius: blurRadius)
    }

    public func blursArtwork(sized sourceSize: CGSize) -> Self {
        var view = self
        view.blurSourceSize = sourceSize
        return view
    }

    /// The pixel size `RemoteImage` requests for a slot — use it with
    /// `ImagePipeline.prefetch(_:pixelSize:)` so prefetched images hit the same cache entry.
    public nonisolated static func pixelSize(forPointSize size: CGSize, scale: CGFloat) -> CGSize {
        // Quantised to 8 px so live-resizing windows don't restart loads every frame.
        func quantise(_ value: CGFloat) -> CGFloat { max(0, (value * scale / 8).rounded(.up) * 8) }
        return CGSize(width: quantise(size.width), height: quantise(size.height))
    }

    private var fitting: ImagePipeline.Fitting { decodingFitting ?? (contentMode == .fill ? .fill : .fit) }

    public var body: some View {
        let key = loadKey
        let image: CGImage? = if let key, let loaded, loaded.key.showsSameArtwork(as: key) {
            loaded.image
        } else if let key {
            ImagePipeline.shared.cachedImage(for: key)
        } else {
            nil
        }

        let artwork = Color.clear
            .overlay(alignment: alignment) {
                if url == nil {
                    if showsPlaceholder {
                        PlaceholderArtwork(seed: placeholderSeed, title: placeholderTitle, style: placeholderStyle)
                    }
                } else {
                    ZStack(alignment: alignment) {
                        if showsPlaceholder, image == nil {
                            PlaceholderArtwork(seed: placeholderSeed, title: placeholderTitle, style: placeholderStyle)
                                // Stay underneath until the artwork has faded in, then drop.
                                .transition(.asymmetric(insertion: .identity, removal: .opacity.animation(.linear(duration: 0.01).delay(0.25))))
                        }
                        if let image {
                            Image(decorative: image, scale: displayScale)
                                .resizable()
                                .interpolation(blurRadius > 0 ? .medium : .high)
                                .aspectRatio(contentMode: contentMode)
                                .transition(.opacity)
                        }
                    }
                }
            }
            .frame(width: size?.width, height: size?.height)
            .clipped()

        if url != nil {
            artwork
                .modifier(MeasureIfNeeded(enabled: size == nil && blurRadius <= 0, size: $measuredSize))
                .task(id: key) {
                    if let key { await load(key) }
                }
                // Lazy stacks can keep a card's state after scrolling past it. The cost-bounded
                // cache controls how long offscreen decoded artwork stays resident.
                .onDisappear { loaded = nil }
        } else {
            artwork
        }
    }

    private func load(_ key: ImagePipeline.Key) async {
        guard loaded?.key != key else { return }
        if let cached = ImagePipeline.shared.cachedImage(for: key) {
            loaded = Loaded(key: key, image: cached)
            return
        }
        if scrollActivity?.isScrolling == true, !progressive {
            // Briefly passing through a row should not start a batch of image downloads and decodes.
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
        }
        // Full-screen artwork: a lighter copy fills the slot while the full resolution downloads.
        // Whichever arrives first wins; a full image already on disk never waits for the copy.
        if progressive, loaded?.key.showsSameArtwork(as: key) != true, let preview = ImagePipeline.previewKey(for: key) {
            await withTaskGroup(of: (isFull: Bool, image: CGImage?).self) { group in
                group.addTask { (true, await ImagePipeline.shared.image(for: key)) }
                group.addTask { (false, await ImagePipeline.shared.image(for: preview)) }
                for await result in group {
                    if result.isFull {
                        group.cancelAll()
                        finish(result.image, key: key)
                        return
                    }
                    if let image = result.image, !Task.isCancelled, loaded?.key != key {
                        withAnimation(imageFade) {
                            loaded = Loaded(key: preview, image: image)
                        }
                    }
                }
            }
            return
        }
        let source = blurSourceSize.flatMap { size in
            ImagePipeline.key(
                url: key.url, pixelSize: Self.pixelSize(forPointSize: size, scale: displayScale),
                fitting: key.fitting, blurRadius: 0
            )
        }
        finish(await ImagePipeline.shared.image(for: key, blurredFrom: source), key: key)
    }

    private func finish(_ image: CGImage?, key: ImagePipeline.Key) {
        guard !Task.isCancelled else { return }
        guard let image else {
            if loaded?.key.showsSameArtwork(as: key) != true { onLoadFailure?() }
            return
        }
        if loaded?.key.showsSameArtwork(as: key) == true {
            // Same artwork at a new resolution: swap in place, no second fade.
            loaded = Loaded(key: key, image: image)
            return
        }
        withAnimation(imageFade) {
            loaded = Loaded(key: key, image: image)
        }
    }
}

private struct MeasureIfNeeded: ViewModifier {
    let enabled: Bool
    @Binding var size: CGSize

    func body(content: Content) -> some View {
        if enabled {
            content.onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newValue in
                size = newValue
            }
        } else {
            content
        }
    }
}

#Preview("RemoteImage") {
    HStack(spacing: 20) {
        RemoteImage(url: nil, size: CGSize(width: 137, height: 205), placeholderSeed: "Foundation", placeholderTitle: "Foundation")
            .clipShape(.rect(cornerRadius: 10))
        RemoteImage(url: URL(string: "https://image.tmdb.org/t/p/w500/invalid.jpg"), placeholderSeed: "Wide", placeholderTitle: "Silo")
            .frame(width: 260, height: 146)
            .clipShape(.rect(cornerRadius: 12))
    }
    .padding(40)
}
