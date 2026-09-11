import Foundation
#if canImport(ActivityKit)
import ActivityKit

struct WindActivityAttributes: ActivityAttributes {
    /// Une balise secondaire, réduite à ce qui tient sur une ligne de l'écran
    /// verrouillé. L'état d'une activité en direct doit rester léger — APNs
    /// plafonne la charge utile à 4 Ko.
    struct SecondaryWind: Codable, Hashable {
        var name: String
        var averageKmh: Double
        var gustKmh: Double
        var directionDegrees: Int
        var isOffline: Bool
    }

    struct ContentState: Codable, Hashable {
        var averageKmh: Double
        var gustKmh: Double
        var minKmh: Double
        var directionDegrees: Int
        var directionLabel: String
        var temperature: Double?
        var readingEpoch: Double
        /// Derniers points (km/h) pour le sparkline de l'île dynamique.
        var trendKmh: [Double]
        var unitRaw: String
        /// Balises à afficher sous la principale. Optionnel : une activité
        /// lancée avant cette version n'en porte pas.
        var secondaries: [SecondaryWind]?

        var unit: WindUnit { WindUnit(rawValue: unitRaw) ?? .kmh }
        var readingDate: Date { Date(timeIntervalSince1970: readingEpoch) }
    }

    var baliseName: String
    var baliseID: Int
}
#endif
