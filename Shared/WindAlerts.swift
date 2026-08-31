import Foundation

/// Réglages des alertes de seuil (vent qui monte / vent qui retombe).
struct AlertSettings: Codable, Equatable {
    var enabled = false
    /// Alerte quand le vent atteint ou dépasse ce seuil.
    var upperEnabled = true
    var upperKmh: Double = 25
    /// Alerte quand le vent retombe sous ce seuil.
    var lowerEnabled = false
    var lowerKmh: Double = 10
    /// Baser les seuils sur les rafales plutôt que sur le vent moyen.
    var useGusts = false
    /// Plage horaire pendant laquelle les alertes sont autorisées (heure locale).
    var startHour = 8
    var endHour = 21
    /// Délai minimal entre deux notifications du même type.
    var cooldownMinutes = 45

    static let `default` = AlertSettings()

    func isWithinWindow(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        if startHour <= endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour  // plage à cheval sur minuit
    }
}

/// État mémorisé entre deux relevés, pour ne notifier que sur un franchissement.
struct AlertState: Codable, Equatable {
    var wasAboveUpper = false
    var wasBelowLower = false
    var lastUpperNotification: Date?
    var lastLowerNotification: Date?
    var lastReadingDate: Date?

    static let empty = AlertState()
}

enum AlertKind: String {
    case upper, lower
}

struct AlertEvent {
    var kind: AlertKind
    var title: String
    var body: String
}

enum AlertEngine {
    /// Décide s'il faut notifier pour ce relevé, et renvoie le nouvel état à persister.
    /// On ne notifie qu'au **franchissement** du seuil (pas à chaque relevé au-dessus),
    /// et jamais deux fois dans la fenêtre de cooldown.
    static func evaluate(reading: WindReading,
                         settings: AlertSettings,
                         state: AlertState,
                         unit: WindUnit,
                         now: Date = .now) -> (event: AlertEvent?, state: AlertState) {
        var state = state
        guard settings.enabled else { return (nil, state) }

        let value = settings.useGusts ? reading.gustKmh : reading.averageKmh
        guard let value else { return (nil, state) }

        // Relevé déjà traité : on ne renotifie pas au réveil suivant.
        if let last = state.lastReadingDate, last >= reading.date { return (nil, state) }
        state.lastReadingDate = reading.date

        // On compare ce que l'utilisateur voit : 24,0 km/h affiché « 13 nds » doit
        // déclencher un seuil réglé sur 13 nds (24,076 km/h en interne).
        let shown = (unit.convert(fromKmh: value)).rounded()
        let upper = (unit.convert(fromKmh: settings.upperKmh)).rounded()
        let lower = (unit.convert(fromKmh: settings.lowerKmh)).rounded()
        let isAbove = settings.upperEnabled && shown >= upper
        let isBelow = settings.lowerEnabled && shown <= lower
        let wasAbove = state.wasAboveUpper
        let wasBelow = state.wasBelowLower
        state.wasAboveUpper = isAbove
        state.wasBelowLower = isBelow

        guard settings.isWithinWindow(now) else { return (nil, state) }

        let source = settings.useGusts ? "rafales" : "vent moyen"
        let formatted = "\(unit.format(kmh: value)) \(unit.symbol)"
        let direction = reading.directionText

        if isAbove && !wasAbove, allowed(state.lastUpperNotification, settings, now) {
            state.lastUpperNotification = now
            return (AlertEvent(kind: .upper,
                               title: "Ça monte 🪁 \(formatted)",
                               body: "\(source.capitalized) au-dessus de \(unit.format(kmh: settings.upperKmh)) \(unit.symbol) · \(direction)"),
                    state)
        }

        if isBelow && !wasBelow, allowed(state.lastLowerNotification, settings, now) {
            state.lastLowerNotification = now
            return (AlertEvent(kind: .lower,
                               title: "Ça tombe 🍃 \(formatted)",
                               body: "\(source.capitalized) sous \(unit.format(kmh: settings.lowerKmh)) \(unit.symbol) · \(direction)"),
                    state)
        }

        return (nil, state)
    }

    private static func allowed(_ last: Date?, _ settings: AlertSettings, _ now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Double(settings.cooldownMinutes) * 60
    }
}
