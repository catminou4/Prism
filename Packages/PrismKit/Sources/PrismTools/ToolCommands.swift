import Foundation

/// A `prism-tools` sub-command.
struct ToolCommand {
    let name: String
    let summary: String
    /// Returns the process exit code.
    let run: @MainActor ([String]) -> Int32
}

/// Registered commands. Add new ones here (e.g. `screens` for full PrismUI screens).
enum ToolCommands {
    static let all: [ToolCommand] = [
        ToolCommand(name: "gallery", summary: "<outputDir> — render the PrismDesign component gallery (light & dark PNGs)", run: GalleryCommand.run),
        ToolCommand(name: "image", summary: "<url> [maxPixelSize] — load one image through ImagePipeline and print timings", run: ImageCommand.run),
        ToolCommand(name: "catalog", summary: "[containerDir] — audit the installed app's cached catalogs and curated shelves", run: CatalogCommand.run),
        ToolCommand(name: "refresh", summary: "[containerDir] — real source refresh benchmark (network + decode + cache write to a scratch dir)", run: RefreshCommand.run),
        ToolCommand(name: "icon", summary: "<appiconsetDir> — render AppIconArtwork into every macOS icon size", run: IconCommand.run),
    ]
}
