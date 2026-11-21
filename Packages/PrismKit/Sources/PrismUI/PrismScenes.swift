import SwiftUI

/// All scenes of the app. The Xcode app target only instantiates this.
public struct PrismScenes: Scene {
    public init() {}

    public var body: some Scene {
        WindowGroup("Prism", id: "main") {
            Text("Prism")
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1440, height: 900)
    }
}
