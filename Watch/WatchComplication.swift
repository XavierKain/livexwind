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
}

struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry {
        WatchEntry(date: .now, snapshot: .placeholder(), unit: .kmh)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) {
        let cached = SharedStore.shared.loadSnapshot(key: SharedStore.shared.catalog.selectedKey)
        completion(WatchEntry(date: .now, snapshot: cached ?? .placeholder(),
                              unit: SharedStore.shared.unit))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) {
        Task {
            let snapshot = await WatchFeed.load()
            let entry = WatchEntry(date: .now, snapshot: snapshot, unit: SharedStore.shared.unit)

            // watchOS rationne les rafraîchissements de complication comme iOS ceux
            // des widgets : viser la minute ne ferait que griller le budget plus
            // vite pour le même résultat. On demande le prochain relevé, plancher
            // à 10 min, et l'ouverture de l'app rafraîchit immédiatement.
            var next = snapshot.nextExpectedUpdate
            if next.timeIntervalSinceNow < 600 {
                next = Date().addingTimeInterval(600)
            }
            completion(Timeline(entries: [entry], policy: .after(next)))
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
    private var color: Color { WindPalette.color(kmh: reading.averageKmh) }
    private var speed: String { entry.unit.format(kmh: reading.averageKmh) }

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
            Text(speed)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.7)
        }
        .gaugeStyle(.accessoryCircular)
        .tint(color)
    }

    private var corner: some View {
        Text(speed)
            .font(.system(size: 17, weight: .bold, design: .rounded))
            .widgetCurvesContent()
            .widgetLabel {
                Text("\(reading.compass) · raf \(entry.unit.format(kmh: reading.gustKmh))")
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
