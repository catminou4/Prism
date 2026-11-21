import SwiftUI

/// Centred empty state (Apple TV `16_films_lib`): large gray glyph or the Prism mark, 22 pt
/// bold title, 13 pt secondary message and a small bordered action.
public struct EmptyStateView: View {
    public enum Glyph: Sendable {
        case symbol(String)
        case logo
    }

    private let glyph: Glyph
    private let title: String
    private let message: String?
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(glyph: Glyph = .logo, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    /// Convenience with an SF Symbol name.
    public init(symbol: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(glyph: .symbol(symbol), title: title, message: message, actionTitle: actionTitle, action: action)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch glyph {
                case .symbol(let name):
                    Image(systemName: name)
                        .font(.system(size: 60, weight: .medium))
                        .foregroundStyle(.tertiary)
                case .logo:
                    PrismLogoLockup(size: 48, style: .monochrome(Color(white: 0.5)), wordmarkColor: Color(white: 0.5))
                }
            }
            .padding(.bottom, 16)
            Text(title)
                .font(PrismFont.emptyTitle)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(PrismFont.emptyMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.top, 8)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .padding(.top, 12)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

#Preview("EmptyStateView") {
    HStack {
        EmptyStateView(title: "Ajouter à la bibliothèque", message: "Les films et séries que vous ajoutez à Ma liste s'afficheront ici.", actionTitle: "Parcourir l'accueil") {}
        EmptyStateView(symbol: "star", title: "Aucune chaîne favorite", message: "Ajoutez des chaînes à vos favoris depuis TV en direct.")
    }
    .frame(width: 900, height: 420)
}
