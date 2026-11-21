import PrismCore

// PrismData — everything between the raw sources (PrismCore) and the UI (PrismUI).
//
// • Catalog/      `CatalogBuilder.build` (off-main, parallel) merges per-source `SourceCatalog`s into an
//                 immutable, indexed `Catalog` (titles grouped across sources/qualities, channel groups,
//                 category groups, O(1) lookups, featured / top-rated / related shelves).
// • Search/       `SearchIndex` — prefix-word, accent-insensitive search over the whole catalog.
// • EPG/          `EPGGuide` — per-channel sorted programmes, binary-searched now/next and timelines.
// • Stores/       `AppDirectories`, `SourceStore` (JSON), `CredentialStoring` (Keychain / in-memory),
//                 `CatalogCache` / `EPGCache` (segmented JSON + LZFSE, parallel), `LibraryStore`
//                 (`@MainActor @Observable`: watchlist, favourites, resume points, history…).
// • Repositories/ `CatalogRepository` (import/refresh with progress stream, validation),
//                 `EPGRepository`, `DetailRepository`, `MetadataRepository` (TMDB, optional).
// • Demo/         `DemoContent` (offline-ready demo source with public streams & open movies) and
//                 `PreviewData` (deterministic data for SwiftUI previews and snapshot tests).
