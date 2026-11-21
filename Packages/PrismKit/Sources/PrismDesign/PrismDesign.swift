import SwiftUI

/// PrismDesign — the Prism design system.
///
/// Replicates the Apple TV app for Mac (macOS 26 Liquid Glass era): tokens (`PrismMetrics`,
/// `PrismFont`, `PrismMotion`, `PrismTint`), the shared `ImagePipeline` + `RemoteImage`,
/// glass controls, badges, cards, shelves, hero carousel, brand assets and onboarding visuals.
///
/// The module is intentionally generic: it never imports PrismCore and only takes plain
/// values (strings, URLs, doubles, closures).
public enum PrismDesign {
    /// Bumped when visual tokens change in a way snapshot consumers should notice.
    public static let version = "1.0"
}
