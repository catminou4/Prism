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
    private let onLoadFailure: (() -> Void)?

    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        self.onLoadFailure = onLoadFailure
    }

    private struct Loaded: Equatable {
        let key: LoadKey
        let image: CGImage
        static func == (lhs: Loaded, rhs: Loaded) -> Bool { lhs.key == rhs.key && lhs.image === rhs.image }
    }

    private struct LoadKey: Hashable {
        let url: URL?
        let pixelWidth: Int
        let pixelHeight: Int
        let fitting: ImagePipeline.Fitting
    }

    private var pointSize: CGSize { size ?? measuredSize }

    private var loadKey: LoadKey {
        let pixels = Self.pixelSize(forPointSize: pointSize, scale: displayScale)
        return LoadKey(url: url, pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height), fitting: fitting)
    }

    /// The pixel size `RemoteImage` requests for a slot — use it with
    /// `ImagePipeline.prefetch(_:pixelSize:)` so prefetched images hit the same cache entry.
    public nonisolated static func pixelSize(forPointSize size: CGSize, scale: CGFloat) -> CGSize {
        // Quantised to 8 px so live-resizing windows don't restart loads every frame.
        func quantise(_ value: CGFloat) -> CGFloat { max(0, (value * scale / 8).rounded(.up) * 8) }
        return CGSize(width: quantise(size.width), height: quantise(size.height))
    }

    private var pixelSize: CGSize {
        let key = loadKey
        return CGSize(width: key.pixelWidth, height: key.pixelHeight)
    }

    private var fitting: ImagePipeline.Fitting { decodingFitting ?? (contentMode == .fill ? .fill : .fit) }

    public var body: some View {
        let key = loadKey
        let image: CGImage? = if let loaded, loaded.key.url == key.url, loaded.key.fitting == key.fitting {
            loaded.image
        } else if let url, key.pixelWidth > 0 {
            ImagePipeline.shared.cachedImage(for: url, pixelSize: pixelSize, fitting: key.fitting, blurRadius: blurRadius)
        } else {
            nil
        }

        Color.clear
            .overlay(alignment: alignment) {
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
            .frame(width: size?.width, height: size?.height)
            .clipped()
            .modifier(MeasureIfNeeded(enabled: size == nil, size: $measuredSize))
            .task(id: key) { await load(key) }
    }

    private func load(_ key: LoadKey) async {
        guard let url = key.url, key.pixelWidth > 0, key.pixelHeight > 0 else { return }
        if let loaded, loaded.key == key { return }
        let target = CGSize(width: key.pixelWidth, height: key.pixelHeight)
        if let cached = ImagePipeline.shared.cachedImage(for: url, pixelSize: target, fitting: key.fitting, blurRadius: blurRadius) {
            loaded = Loaded(key: key, image: cached)
            return
        }
        let image = await ImagePipeline.shared.image(for: url, pixelSize: target, fitting: key.fitting, blurRadius: blurRadius)
        guard !Task.isCancelled else { return }
        guard let image else {
            if loaded?.key.url != url || loaded?.key.fitting != key.fitting { onLoadFailure?() }
            return
        }
        withAnimation(PrismMotion.respecting(reduceMotion, PrismMotion.imageFade)) {
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
