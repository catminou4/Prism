import SwiftUI

/// Logo intro: the three facets spring in from scattered positions, a light sweep crosses the
/// assembled prism, then the wordmark de-blurs in (~1.6 s). Reduce Motion → a simple fade.
public struct AnimatedPrismLogo: View {
    private let play: Bool
    private let size: CGFloat
    private let axis: Axis
    private let wordmarkColor: Color
    private let onFinished: (() -> Void)?

    @State private var time: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Total duration in seconds.
    public static let duration: Double = 1.6

    /// - Parameters:
    ///   - play: Starts the animation when it becomes `true` (or is `true` on appear).
    ///   - size: Wordmark point size.
    public init(play: Bool, size: CGFloat = 40, axis: Axis = .vertical, wordmarkColor: Color = .white, onFinished: (() -> Void)? = nil) {
        self.play = play
        self.size = size
        self.axis = axis
        self.wordmarkColor = wordmarkColor
        self.onFinished = onFinished
    }

    public var body: some View {
        Group {
            if reduceMotion {
                PrismLogoLockup(size: size, axis: axis, wordmarkColor: wordmarkColor)
                    .opacity(time > 0 ? 1 : 0)
            } else {
                LogoTimeline(time: time, size: size, axis: axis, wordmarkColor: wordmarkColor)
            }
        }
        .task(id: play) {
            guard play else {
                time = 0
                return
            }
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.4)) { time = Self.duration }
                try? await Task.sleep(for: .seconds(0.4))
            } else {
                time = 0
                withAnimation(.linear(duration: Self.duration)) { time = Self.duration }
                try? await Task.sleep(for: .seconds(Self.duration))
            }
            guard !Task.isCancelled else { return }
            onFinished?()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Prism")
    }
}

/// A still frame of the logo intro at `time` seconds (snapshots, design reviews).
public struct AnimatedPrismLogoFrame: View {
    private let time: Double
    private let size: CGFloat
    private let axis: Axis
    private let wordmarkColor: Color

    public init(time: Double, size: CGFloat = 28, axis: Axis = .vertical, wordmarkColor: Color = .white) {
        self.time = time
        self.size = size
        self.axis = axis
        self.wordmarkColor = wordmarkColor
    }

    public var body: some View {
        LogoTimeline(time: time, size: size, axis: axis, wordmarkColor: wordmarkColor)
    }
}

/// Renders the intro at a given time; `Animatable` so a single linear animation of `time`
/// drives every track (springs are evaluated analytically per frame).
private struct LogoTimeline: View, Animatable {
    var time: Double
    let size: CGFloat
    let axis: Axis
    let wordmarkColor: Color

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    private static let facetSpring = Spring(duration: 0.62, bounce: 0.22)

    private func facetProgress(delay: Double) -> Double {
        let local = time - delay
        guard local > 0 else { return 0 }
        return Self.facetSpring.value(target: 1.0, time: local)
    }

    var body: some View {
        let facets = [facetProgress(delay: 0.0), facetProgress(delay: 0.09), facetProgress(delay: 0.18)]
        let sweep: Double? = (0.62...1.12).contains(time) ? -0.4 + (time - 0.62) / 0.5 * 1.8 : nil
        let word = min(max((time - 0.86) / 0.6, 0), 1)
        let eased = 1 - pow(1 - word, 3)
        let markSize = axis == .horizontal ? size * 1.25 : size * 2.4
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: size * 0.22))
            : AnyLayout(VStackLayout(spacing: size * 0.35))
        layout {
            PrismLogoMark(size: markSize, style: .spectral, facetAssembly: facets, sweep: sweep)
                .scaleEffect(0.9 + 0.1 * min(1, facets.reduce(0, +) / 3))
            PrismWordmark(size: size, color: wordmarkColor)
                .opacity(eased)
                .blur(radius: (1 - eased) * 10)
                .offset(y: axis == .vertical ? (1 - eased) * 8 : 0)
                .offset(x: axis == .horizontal ? (1 - eased) * -10 : 0)
        }
    }
}

#Preview("AnimatedPrismLogo") {
    @Previewable @State var play = false
    VStack(spacing: 30) {
        AnimatedPrismLogo(play: play)
        Button("Rejouer") { play.toggle() }
    }
    .frame(width: 400, height: 360)
    .background(.black)
    .onAppear { play = true }
}
