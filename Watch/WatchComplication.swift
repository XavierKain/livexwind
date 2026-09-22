import WidgetKit
import SwiftUI

@main
struct LiveXWindWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        WatchWindComplication()
    }
}

struct WatchEntry: TimelineEntry {
    let date: Date
    let snapshot: WindSnapshot
    let unit: WindUnit
    /// À l'heure de cette entrée, le relevé n'est plus le vent du moment.
    ///
    /// Une complication ne se redessine pas toute seule entre deux
    /// rafraîchissements, et watchOS les rationne : sans cette information
    /// portée par la timeline, un chiffre d'il y a une heure continuait de
    /// s'afficher comme s'il était frais jusqu'à ce qu'on la touche.
    var isStale: Bool = false
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry {
        WatchEntry(date: .now, snapshot: .placeholder(), unit: .kmh)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        let cached = SharedStore.shared.loadSnapshot(key: SharedStore.shared.catalog.selectedKey)
        let snapshot = cached ?? .placeholder()
        completion(WatchEntry(date: .now, snapshot: snapshot,
                              unit: SharedStore.shared.unit,
                              isStale: snapshot.isStale()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        Task {
            // L'unité vient du serveur avec le relevé : c'est le seul moyen pour
            // cette extension de connaître le choix fait sur l'iPhone.
            let reading = await WatchFeed.load()
            let snapshot = reading.snapshot
            let now = Date()

            // Deux entrées plutôt qu'une : le relevé tant qu'il vaut, puis le
            // même en tiret à la seconde où il cesse d'être le vent du moment.
            // C'est ce qui fait qu'une complication qu'on n'a pas touchée se
            // démode d'elle-même au lieu d'afficher un chiffre périmé.
            var entries = [WatchEntry(date: now, snapshot: snapshot, unit: reading.unit,
                                      isStale: snapshot.isStale(at: now))]
            let staleAt = snapshot.current.date.addingTimeInterval(snapshot.silenceLimit)
            if staleAt > now {
                entries.append(WatchEntry(date: staleAt, snapshot: snapshot,
                                          unit: reading.unit, isStale: true))
            }

            // watchOS rationne les rafraîchissements de complication comme iOS ceux
            // des widgets : viser la minute ne ferait que griller le budget plus
            // vite pour le même résultat. On demande le prochain relevé, plancher
            // à 10 min, et l'ouverture de l'app rafraîchit immédiatement.
            var next = snapshot.nextExpectedUpdate
            if next.timeIntervalSinceNow < 600 {
                next = now.addingTimeInterval(600)
            }
            completion(Timeline(entries: entries, policy: .after(next)))
        }
    }
}

struct WatchWindComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LiveXWindComplication", provider: WatchProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Vent")
        .description("Le vent de la balise affichée sur l'iPhone.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner,
                            .accessoryRectangular, .accessoryInline])
    }
}

struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchEntry

    private var reading: WindReading { entry.snapshot.current }
    /// Le verdict est porté par l'entrée, pas recalculé ici : une complication
    /// est dessinée à l'heure de son entrée, pas à l'heure qu'il est.
    private var isOffline: Bool { entry.isStale }
    private var color: Color {
        isOffline ? .secondary : WindPalette.color(kmh: reading.averageKmh)
    }
    /// Un tiret plutôt qu'un chiffre : au poignet, une valeur périmée serait
    /// prise pour le vent du moment sans qu'on puisse la mettre en doute.
    private var speed: String {
        isOffline ? "—" : entry.unit.format(kmh: reading.averageKmh)
    }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        case .accessoryCorner: corner
        case .accessoryInline:
            Text("\(reading.compass) \(speed)/\(entry.unit.format(kmh: reading.gustKmh)) \(entry.unit.shortSymbol)")
        default: circular
        }
    }

    private var circular: some View {
        Gauge(value: min(reading.averageKmh ?? 0, 60), in: 0...60) {
            WindArrow(degrees: reading.directionDegrees).frame(width: 7, height: 7)
        } currentValueLabel: {
            VStack(spacing: -2) {
                Text(speed)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                Text(reading.compass)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(color)
    }

    /// Coin de cadran.
    ///
    /// Le coin prend tout l'espace disponible pour le vent et sa flèche ; l'arc
    /// ne porte que le secteur et la rafale. L'unité en est retirée : elle se
    /// règle sur l'iPhone et ne change pas d'un coup d'œil à l'autre, alors
    /// qu'elle faisait tronquer le reste de la ligne.
    private var corner: some View {
        // Chiffre puis flèche, comme dans l'île dynamique : on lit la force,
        // puis d'où vient le vent.
        HStack(spacing: 2) {
            Text(speed)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            WindArrow(degrees: isOffline ? nil : reading.directionDegrees, color: color)
                .frame(width: 19, height: 19)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetLabel {
            // Le vent est répété ici : le coin est au bord de l'écran, l'arc se
            // lit plus facilement d'un coup d'œil.
            Text("\(speed) \(reading.compass) · R \(entry.unit.format(kmh: reading.gustKmh))")
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                WindArrow(degrees: reading.directionDegrees)
                    .frame(width: 9, height: 9)
                Text(entry.snapshot.baliseName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(speed)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(entry.unit.shortSymbol).font(.system(size: 9))
                Text("raf \(entry.unit.format(kmh: reading.gustKmh))").font(.system(size: 11))
            }
            WindSparkline(values: entry.snapshot.window(hours: 3).compactMap(\.averageKmh),
                          color: .primary)
                .frame(height: 10)
        }
    }
}
