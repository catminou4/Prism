import PrismDesign
import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.prismSnapshotRendering) private var snapshotRendering
    @State private var showsSetup = false
    @State private var setupStep = SetupStep.welcome
    @State private var artworkRevealed = false

    private enum SetupStep {
        case welcome, source, demo
    }

    var body: some View {
        ZStack {
            PosterWall(tileWidth: 170, angle: .degrees(-10), speed: 9, vignette: 0.76, isAnimating: !showsSetup && !snapshotRendering)
                .ignoresSafeArea()
            LinearGradient(
                stops: [.init(color: .black.opacity(0.08), location: 0), .init(color: Color(white: 0.025).opacity(0.92), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            VStack(spacing: 21) {
                if snapshotRendering {
                    PrismLogoLockup(size: 52, axis: .vertical, wordmarkColor: .white)
                } else {
                    AnimatedPrismLogo(play: true, size: 52, wordmarkColor: .white) {
                        withAnimation(.easeOut(duration: 0.28)) { artworkRevealed = true }
                    }
                }
                VStack(spacing: 13) {
                    Text("Votre télévision,\nà votre façon.")
                        .font(.system(size: 60, weight: .bold))
                        .tracking(-2.5)
                        .accessibilityAddTraits(.isHeader)
                    Text("Chaînes en direct, films et séries réunis sur votre Mac.")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .multilineTextAlignment(.center)
                .opacity(artworkRevealed || reduceMotion || snapshotRendering ? 1 : 0)
                .offset(y: artworkRevealed || reduceMotion || snapshotRendering ? 0 : 8)
                VStack(spacing: 16) {
                    PrimaryCapsuleButton("Commencer", systemImage: "arrow.right", height: 46, minWidth: 190) {
                        show(.welcome)
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Essayer la démo") { show(.demo) }
                        .buttonStyle(.link)
                        .tint(.white.opacity(0.78))
                }
                .padding(.top, 8)
            }
            .foregroundStyle(.white)
            .padding(40)
        }
        .prismDarkBackground()
        .sheet(isPresented: $showsSetup) {
            Group {
                switch setupStep {
                case .welcome:
                    WelcomePanel {
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { setupStep = .source }
                    }
                case .source, .demo:
                    AddSourceView(allowsDemo: true, startsDemo: setupStep == .demo) {
                        showsSetup = false
                        model.completeOnboarding()
                    }
                }
            }
            .transition(.opacity)
        }
    }

    private func show(_ step: SetupStep) {
        setupStep = step
        showsSetup = true
    }
}

private struct WelcomePanel: View {
    @Environment(\.dismiss) private var dismiss
    let onContinue: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 13) {
                PrismLogoMark(size: 43)
                    .accessibilityHidden(true)
                Text("Bienvenue dans Prism")
                    .font(.system(size: 31, weight: .bold))
                    .tracking(-0.8)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(alignment: .leading, spacing: 19) {
                feature("TV en direct", "Retrouvez vos chaînes et les programmes du guide.", icon: "play.tv")
                feature("Films et séries", "Explorez votre catalogue et reprenez votre lecture.", icon: "film.stack")
                feature("Toutes vos sources", "Choisissez la langue et la source depuis une seule fiche.", icon: "square.stack.3d.up")
            }
            Spacer(minLength: 8)
            Text("Les mots de passe Xtream sont enregistrés dans le Trousseau de votre Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Retour", action: { dismiss() })
                    .keyboardShortcut(.cancelAction)
                Spacer()
                PrimaryCapsuleButton("Continuer", style: .accent, height: 42, action: onContinue)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 546, height: 490)
    }

    private func feature(_ title: String, _ detail: String, icon: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
