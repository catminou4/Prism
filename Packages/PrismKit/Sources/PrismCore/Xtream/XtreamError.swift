import Foundation

public enum XtreamError: Error, LocalizedError, Equatable {
    case invalidServer
    case unauthorized
    case accountExpired(Date?)
    case accountDisabled(String)
    case http(Int)
    case decoding(String)
    case secureConnectionRequired
    case untrustedSecureConnection
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidServer:
            "Adresse du serveur invalide."
        case .unauthorized:
            "Identifiants refusés par le serveur."
        case .accountExpired(let date):
            if let date {
                "Abonnement expiré depuis le \(date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR"))))."
            } else {
                "Abonnement expiré."
            }
        case .accountDisabled(let status):
            "Compte désactivé par le fournisseur (\(status))."
        case .http(let code):
            "Le serveur a répondu avec une erreur (HTTP \(code))."
        case .decoding:
            "Réponse du serveur illisible."
        case .secureConnectionRequired:
            "macOS exige une connexion HTTPS à ce serveur."
        case .untrustedSecureConnection:
            "La connexion HTTPS du serveur n’a pas pu être vérifiée."
        case .network(let message):
            "Connexion au serveur impossible : \(message)"
        }
    }

    public var failureReason: String? {
        switch self {
        case .decoding(let detail): detail
        default: nil
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .invalidServer: "Vérifiez l’adresse (ex. http://exemple.com:8080)."
        case .unauthorized: "Vérifiez le nom d’utilisateur et le mot de passe."
        case .accountExpired: "Renouvelez votre abonnement auprès de votre fournisseur."
        case .secureConnectionRequired, .untrustedSecureConnection:
            "Demandez à votre fournisseur une adresse HTTPS valide."
        case .network: "Vérifiez votre connexion Internet ou réessayez plus tard."
        default: nil
        }
    }
}
