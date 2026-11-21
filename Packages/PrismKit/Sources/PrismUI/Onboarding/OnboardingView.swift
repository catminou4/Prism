import PrismDesign
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.prismSnapshotRendering) private var snapshotRendering
    @State private var entry: Entry?

    private enum Entry: String, Identifiable {
        case source, demo

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            PosterWall(tileWidth: 190, angle: .degrees(-6), speed: 5, vignette: 0.85,
                       isAnimating: entry == nil && !snapshotRendering)
                .saturation(0)
                .opacity(0.35)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            RadialGradient(colors: [Color(white: 0.055), Color(white: 0.025).opacity(0.1)],
                           center: .center, startRadius: 115, endRadius: 560)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 24) {
                if snapshotRendering {
                    PrismLogoLockup(size: 39, axis: .vertical, style: .onDark, wordmarkColor: .white)
                } else {
                    AnimatedPrismLogo(play: true, size: 39, wordmarkColor: .white)
                }
                VStack(spacing: 9) {
                    Text("Votre bibliothèque IPTV")
                        .font(.system(size: 41, weight: .semibold))
                        .tracking(-1.25)
                        .accessibilityAddTraits(.isHeader)
                    Text("Chaînes, films et séries de vos sources sur votre Mac.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.75))
                }
                .multilineTextAlignment(.center)
                HStack(spacing: 9) {
                    Button("Essayer la démo") { entry = .demo }
                        .buttonStyle(.glass)
                    Button("Ajouter une source", systemImage: "plus") {
                        entry = .source
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .environment(\.colorScheme, .dark)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .prismDarkBackground()
        .sheet(item: $entry) { entry in
            AddSourceView(allowsDemo: true, startsDemo: entry == .demo) {
                self.entry = nil
                model.completeOnboarding()
            }
        }
    }
}
