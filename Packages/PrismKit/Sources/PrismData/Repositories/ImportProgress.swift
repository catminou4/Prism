import Foundation
import PrismCore

/// Stage of a source import / refresh, in order of appearance.
public enum ImportStage: Sendable, Equatable {
    case connecting
    case account(XtreamAccount)
    case downloading(fraction: Double?)
    case parsing
    case channels(Int)
    case movies(Int)
    case series(Int)
    case guide(Int)
    case finished
}

public struct ImportCounts: Sendable, Hashable {
    public var channels: Int
    public var movies: Int
    public var series: Int
    public var programs: Int

    public init(channels: Int = 0, movies: Int = 0, series: Int = 0, programs: Int = 0) {
        self.channels = channels
        self.movies = movies
        self.series = series
        self.programs = programs
    }

    public init(_ catalog: SourceCatalog) {
        self.init(channels: catalog.channels.count, movies: catalog.movies.count, series: catalog.series.count)
    }
}

/// One element of `CatalogRepository.refresh(_:)`. The last element has stage `.finished` and
/// carries the resulting `catalog` (already saved to the disk cache).
public struct ImportProgress: Sendable {
    public var stage: ImportStage
    public var counts: ImportCounts
    /// Overall progress, 0…1.
    public var fraction: Double
    /// Set on `.finished`.
    public var catalog: SourceCatalog?
    /// XMLTV URLs announced by the playlist header (`url-tvg` / `x-tvg-url`), set on `.finished`.
    public var epgURLs: [URL]

    public init(stage: ImportStage, counts: ImportCounts = .init(), fraction: Double, catalog: SourceCatalog? = nil, epgURLs: [URL] = []) {
        self.stage = stage
        self.counts = counts
        self.fraction = min(max(fraction, 0), 1)
        self.catalog = catalog
        self.epgURLs = epgURLs
    }
}

/// Result of a quick source check (onboarding form "Se connecter").
public struct SourceValidation: Sendable, Hashable {
    public var account: XtreamAccount?
    public var sampleCounts: ImportCounts?

    public init(account: XtreamAccount? = nil, sampleCounts: ImportCounts? = nil) {
        self.account = account
        self.sampleCounts = sampleCounts
    }
}

/// Source-level failures (Xtream API errors are reported as `XtreamError`).
public enum SourceError: Error, LocalizedError, Equatable {
    case missingURL
    case missingCredentials
    case missingFile
    case fileAccessDenied
    case notAPlaylist
    case emptyPlaylist
    case noGuide
    case invalidGuide
    case unauthorized
    case http(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingURL: "Adresse de la playlist manquante ou invalide."
        case .missingCredentials: "Identifiants manquants pour cette source."
        case .missingFile: "Fichier introuvable."
        case .fileAccessDenied: "Accès au fichier refusé. Sélectionnez-le à nouveau."
        case .notAPlaylist: "Ce lien ne renvoie pas une playlist M3U."
        case .emptyPlaylist: "La playlist ne contient aucune chaîne ni vidéo."
        case .noGuide: "Aucun guide TV (XMLTV) n’est disponible pour cette source."
        case .invalidGuide: "Le guide TV (XMLTV) est illisible."
        case .unauthorized: "Accès refusé par le serveur."
        case .http(let code): "Le serveur a répondu avec une erreur (HTTP \(code))."
        case .network(let message): "Connexion impossible : \(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .missingURL, .notAPlaylist: "Vérifiez l’adresse de la playlist (elle doit commencer par #EXTM3U)."
        case .fileAccessDenied, .missingFile: "Ajoutez de nouveau le fichier depuis les réglages de la source."
        case .network: "Vérifiez votre connexion Internet ou réessayez plus tard."
        default: nil
        }
    }

    static func from(_ error: URLError) -> any Error {
        switch error.code {
        case .cancelled: CancellationError()
        case .badURL, .unsupportedURL: SourceError.missingURL
        case .userAuthenticationRequired: SourceError.unauthorized
        default: SourceError.network(error.localizedDescription)
        }
    }

    static func check(status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw SourceError.unauthorized
        default: throw SourceError.http(status)
        }
    }
}
