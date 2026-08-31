import AppIntents
import WidgetKit

/// Configuration du widget (appui long → « Modifier le widget ») :
/// permet de basculer l'affichage entre km/h et nœuds sans ouvrir l'app.
struct WindConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vent balise"
    static var description = IntentDescription("Choisis l'unité et la fenêtre du graphe.")

    @Parameter(title: "Balise")
    var balise: BaliseEntity?

    @Parameter(title: "Unité", default: .kmh)
    var unit: WindUnitChoice

    @Parameter(title: "Fenêtre du graphe", default: .sixHours)
    var window: WindWindowChoice

    init() {}
}

enum WindUnitChoice: String, AppEnum {
    case kmh
    case knots

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Unité")
    static var caseDisplayRepresentations: [WindUnitChoice: DisplayRepresentation] = [
        .kmh: "km/h",
        .knots: "nœuds"
    ]

    var unit: WindUnit { self == .kmh ? .kmh : .knots }
}

enum WindWindowChoice: String, AppEnum {
    case threeHours
    case sixHours
    case twelveHours
    case day

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Fenêtre")
    static var caseDisplayRepresentations: [WindWindowChoice: DisplayRepresentation] = [
        .threeHours: "3 heures",
        .sixHours: "6 heures",
        .twelveHours: "12 heures",
        .day: "24 heures"
    ]

    var hours: Double {
        switch self {
        case .threeHours: return 3
        case .sixHours: return 6
        case .twelveHours: return 12
        case .day: return 24
        }
    }
}


/// Balise proposée dans la configuration du widget. La liste vient du serveur —
/// l'extension widget n'a pas accès aux réglages de l'app (pas d'App Group).
struct BaliseEntity: AppEntity, Identifiable, Hashable {
    var id: Int
    var name: String
    var altitude: Int?
    var providerRaw: String = BaliseProvider.ffvl.rawValue

    var balise: Balise {
        Balise(id: id, name: name, altitude: altitude,
               provider: BaliseProvider(rawValue: providerRaw) ?? .ffvl)
    }

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Balise")
    static var defaultQuery = BaliseQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)",
                              subtitle: altitude.map { "#\(id) · \($0) m" } ?? "#\(id)")
    }

    static let pyla = BaliseEntity(id: Balise.pyla.id, name: Balise.pyla.name,
                                   altitude: Balise.pyla.altitude,
                                   providerRaw: Balise.pyla.provider.rawValue)
}

struct BaliseQuery: EntityQuery {
    func entities(for identifiers: [Int]) async throws -> [BaliseEntity] {
        let known = try? await ServerClient.shared.fetchBalises()
        return identifiers.map { id in
            if let match = known?.first(where: { $0.id == id }) {
                return BaliseEntity(id: id, name: match.name ?? "Balise \(id)",
                                    altitude: match.altitude,
                                    providerRaw: match.provider ?? BaliseProvider.ffvl.rawValue)
            }
            return BaliseEntity(id: id, name: "Balise \(id)", altitude: nil)
        }
    }

    func suggestedEntities() async throws -> [BaliseEntity] {
        guard let remote = try? await ServerClient.shared.fetchBalises(), !remote.isEmpty else {
            return [.pyla]
        }
        return remote.map {
            BaliseEntity(id: $0.id, name: $0.name ?? "Balise \($0.id)", altitude: $0.altitude,
                         providerRaw: $0.provider ?? BaliseProvider.ffvl.rawValue)
        }
    }

    func defaultResult() async -> BaliseEntity? { .pyla }
}
