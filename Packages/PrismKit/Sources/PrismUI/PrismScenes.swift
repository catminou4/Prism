import AppKit
import SwiftUI
import PrismDesign

/// The app target hosts the native library, settings, and independent player window.
public struct PrismScenes: Scene {
    /// Purge the decoded-image memory cache when the system reports pressure —
    /// `purgeMemory()` existed but nothing ever called it. Resumed once, lazily.
    private static let memoryPressurePurge: any DispatchSourceMemoryPressure = {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { ImagePipeline.shared.purgeMemory() }
        source.resume()
        return source
    }()

    @State private var model = AppModel()
    @State private var playback = PrismPlaybackSession()
    @State private var heroPreview = HeroPreviewSession()

    public init() { _ = Self.memoryPressurePurge }

    public var body: some Scene {
        Window("Prism", id: "main") {
            PrismRootView(playback: playback)
                .environment(model)
                .environment(heroPreview)
                .environment(playback)
                .frame(minWidth: 1100, minHeight: 700)
                .task { await model.bootstrap() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    playback.close()
                    heroPreview.stop()
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
    @Environment(HeroPreviewSession.self) private var heroPreview
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
            heroPreview.stop()
            playback.open(item, target: target, contentID: contentID, app: app, seriesEditionID: seriesEditionID)
            openWindow(id: PrismPlaybackSession.windowID)
        })
        .animation(reduceMotion ? nil : .smooth(duration: 0.38), value: app.phase)
    }
}
