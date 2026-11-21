import SwiftUI

/// One row of an `InfoColumn`.
nonisolated public struct InfoRow: Hashable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var id: String { label }

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Detail page info column (`Informations`, `Technique`, `Source`): 17 bold title, then
/// label (12 medium) / value (12 secondary) pairs. Empty values are skipped.
public struct InfoColumn: View {
    private let title: String
    private let rows: [InfoRow]

    public init(title: String, rows: [InfoRow]) {
        self.title = title
        self.rows = rows.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Tuple convenience: `InfoColumn(title: "Informations", rows: [("Sortie", "2022")])`.
    public init(title: String, rows: [(label: String, value: String)]) {
        self.init(title: title, rows: rows.map { InfoRow($0.label, $0.value) })
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(PrismFont.sectionTitle)
                .foregroundStyle(.primary)
                .padding(.bottom, 2)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.label)
                        .font(PrismFont.infoLabel)
                        .foregroundStyle(.primary)
                    Text(row.value)
                        .font(PrismFont.infoValue)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

#Preview("InfoColumn") {
    HStack(alignment: .top, spacing: 40) {
        InfoColumn(title: "Informations", rows: [("Sortie", "2022"), ("Durée", "57 min"), ("Genre", "Thriller"), ("Pays", "États-Unis")])
        InfoColumn(title: "Technique", rows: [("Vidéo", "4K HDR"), ("Audio", "Dolby Atmos, 5.1"), ("Conteneur", "MKV")])
        InfoColumn(title: "Source", rows: [("Fournisseur", "Source A"), ("Catégorie", "Séries US"), ("Ajouté le", "21 nov. 2026")])
    }
    .frame(width: 800)
    .padding(40)
}
