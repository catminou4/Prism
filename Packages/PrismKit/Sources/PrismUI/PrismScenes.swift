import AppKit
import SwiftUI
import PrismDesign

/// The app target hosts the native library, settings, and independent player window.
public struct PrismScenes: Scene {
    @State private var model = AppModel()
    @State private var playback = PrismPlaybackSession()

    public init() {}

    public var body: some Scene {
        Window("Prism", id: "main") {
            PrismRootView(playback: playback)
                .environment(model)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await model.bootstrap() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    playback.close()
                    model.flush()
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)

        Window("Lecteur Prism", id: PrismPlaybackSession.windowID) {
            PrismPlaybackWindow(session: playback)
                .environment(model)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 1080, height: 608)
        .windowStyle(.hiddenTitleBar)

        Settings {
            PrismSettingsView().environment(model)
        }
    }
}

struct PrismRootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let playback: PrismPlaybackSession

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                VStack(spacing: 24) {
                    PrismLogoLockup(size: 42)
                    ProgressView().controlSize(.small).accessibilityLabel("Chargement de Prism")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .onboarding: OnboardingView()
            case .ready: LibraryShell()
            }
        }
        .environment(\.playPrismItem, PrismPlaybackAction(owner: playback) { item, target, contentID, seriesEditionID in
            playback.open(item, target: target, contentID: contentID, app: app, seriesEditionID: seriesEditionID)
            openWindow(id: PrismPlaybackSession.windowID)
        })
        .animation(reduceMotion ? nil : .smooth(duration: 0.38), value: app.phase)
    }
}
