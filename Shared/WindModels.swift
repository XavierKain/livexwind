import Foundation

// MARK: - Unités

enum WindUnit: String, CaseIterable, Codable, Sendable {
    case kmh
    case knots

    var symbol: String { self == .kmh ? "km/h" : "nds" }
    var shortSymbol: String { self == .kmh ? "km/h" : "kt" }
    var next: WindUnit { self == .kmh ? .knots : .kmh }

    /// Le site FFVL publie tout en km/h.
    func convert(fromKmh value: Double) -> Double {
        self == .kmh ? value : value / 1.852
    }

    func format(kmh value: Double?, decimals: Int = 0) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(decimals)f", convert(fromKmh: value))
    }
}

// MARK: - Relevé

struct WindReading: Codable, Hashable, Sendable, Identifiable {
    var date: Date
    var directionDegrees: Int?
    var directionLabel: String?
    var averageKmh: Double?
    var gustKmh: Double?
    var gustDirectionDegrees: Int?
    var minKmh: Double?
    var temperature: Double?
    var luminosity: Double?

    var id: Date { date }

    /// Rose des vents française à 16 secteurs, recalculée si le site ne l'a pas fournie.
    var compass: String {
        if let label = directionLabel, !label.isEmpty { return label }
        guard let deg = directionDegrees else { return "—" }
        let sectors = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                       "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]
        let index = Int((Double(deg) / 22.5).rounded()) % 16
        return sectors[index]
    }

    var directionText: String {
        guard let deg = directionDegrees else { return "—" }
        return "\(compass) · \(deg)°"
    }
}

// MARK: - Instantané complet (relevé + historique)

struct WindSnapshot: Codable, Hashable, Sendable {
    var baliseID: Int
    var baliseName: String
    var altitude: Int?
    var current: WindReading
    var history: [WindReading]
    var fetchedAt: Date

    static let placeholder = WindSnapshot(
        baliseID: 64,
        baliseName: "Pyla Pilat",
        altitude: 55,
        current: WindReading(date: .now, directionDegrees: 270, directionLabel: "O",
                             averageKmh: 21, gustKmh: 28, gustDirectionDegrees: 292,
                             minKmh: 16, temperature: 24, luminosity: 100),
        history: (0..<24).map { i in
            let base = 14.0 + Double((i * 7) % 13)
            return WindReading(date: Date().addingTimeInterval(Double(-600 * (23 - i))),
                               directionDegrees: 250 + (i * 3) % 40,
                               directionLabel: nil,
                               averageKmh: base,
                               gustKmh: base + 6,
                               gustDirectionDegrees: nil,
                               minKmh: max(0, base - 4),
                               temperature: 23)
        },
        fetchedAt: .now
    )

    /// Prochaine publication attendue : la balise émet toutes les 10 min, on se cale
    /// sur la minute du dernier relevé + 10 min + une marge d'une minute.
    var nextExpectedUpdate: Date {
        let next = current.date.addingTimeInterval(600 + 60)
        return next > .now ? next : Date().addingTimeInterval(120)
    }

    var isStale: Bool { Date().timeIntervalSince(current.date) > 25 * 60 }

    func window(hours: Double) -> [WindReading] {
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        let inWindow = history.filter { $0.date >= cutoff }
        return inWindow.isEmpty ? history.suffix(12).map { $0 } : inWindow
    }
}
