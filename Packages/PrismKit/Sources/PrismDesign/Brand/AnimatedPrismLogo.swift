import SwiftUI

/// The two planes settle into place, followed by the wordmark. Reduce Motion uses a fade.
public struct AnimatedPrismLogo: View {
    private let play: Bool
    private let size: CGFloat
    private let axis: Axis
    private let wordmarkColor: Color
    private let onFinished: (() -> Void)?

    @State private var time: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Total duration in seconds.
    public static let duration: Double = 0.72

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
                withAnimation(.easeOut(duration: 0.24)) { time = Self.duration }
                try? await Task.sleep(for: .seconds(0.24))
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

/// Renders the planes and wordmark using the same animation clock.
private struct LogoTimeline: View, Animatable {
    var time: Double
    let size: CGFloat
    let axis: Axis
    let wordmarkColor: Color

    var animatableData: Double {
        get { time }
        set { time = newValue }
    }

    private func progress(from start: Double, duration: Double) -> Double {
        let fraction = min(max((time - start) / duration, 0), 1)
        let remaining = 1 - fraction
        return 1 - remaining * remaining * remaining
    }

    var body: some View {
        let word = progress(from: 0.25, duration: 0.47)
        let markSize = axis == .horizontal ? size * 1.25 : size * 2.4
        let layout = axis == .horizontal
            ? AnyLayout(HStackLayout(spacing: size * 0.22))
            : AnyLayout(VStackLayout(spacing: size * 0.35))
        layout {
            PrismLogoMark(
                size: markSize, style: .adaptive,
                stemProgress: progress(from: 0, duration: 0.40),
                bowlProgress: progress(from: 0.08, duration: 0.44)
            )
            PrismWordmark(size: size, color: wordmarkColor)
                .opacity(word)
                .offset(x: axis == .horizontal ? (1 - word) * -4 : 0, y: axis == .vertical ? (1 - word) * 4 : 0)
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
