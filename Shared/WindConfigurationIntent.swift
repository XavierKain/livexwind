import AppIntents
import WidgetKit

/// Configuration du widget (appui long → « Modifier le widget ») :
/// permet de basculer l'affichage entre km/h et nœuds sans ouvrir l'app.
struct WindConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Vent balise"
    static var description = IntentDescription("Choisis l'unité et la fenêtre du graphe.")

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
