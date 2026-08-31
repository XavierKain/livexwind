import Foundation
#if canImport(ActivityKit)
import ActivityKit

struct WindActivityAttributes: ActivityAttributes {
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

        var unit: WindUnit { WindUnit(rawValue: unitRaw) ?? .kmh }
        var readingDate: Date { Date(timeIntervalSince1970: readingEpoch) }
    }

    var baliseName: String
    var baliseID: Int
}
#endif
