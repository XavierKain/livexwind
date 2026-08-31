import WidgetKit
import SwiftUI
import AppIntents

struct WindEntry: TimelineEntry {
    let date: Date
    let snapshot: WindSnapshot
    let unit: WindUnit
    let windowHours: Double
}

struct WindProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WindEntry {
        WindEntry(date: .now, snapshot: .placeholder, unit: .kmh, windowHours: 6)
    }

    func snapshot(for configuration: WindConfigurationIntent, in context: Context) async -> WindEntry {
        let cached = SharedStore.shared.loadSnapshot() ?? .placeholder
        return WindEntry(date: .now, snapshot: cached,
                         unit: configuration.unit.unit, windowHours: configuration.window.hours)
    }

    func timeline(for configuration: WindConfigurationIntent, in context: Context) async -> Timeline<WindEntry> {
        let snapshot = await BaliseClient.shared.loadSnapshot()
        let entry = WindEntry(date: .now, snapshot: snapshot,
                              unit: configuration.unit.unit, windowHours: configuration.window.hours)

        // On se cale sur la grille de publication de la balise (un relevé toutes les
        // 10 min) : réveil 45 s après l'heure attendue, avec un plancher de 2 min
        // pour rester dans le budget de rafraîchissement de WidgetKit.
        var next = snapshot.current.date.addingTimeInterval(600 + 45)
        if next.timeIntervalSinceNow < 120 {
            next = Date().addingTimeInterval(120)
        }
        return Timeline(entries: [entry], policy: .after(next))
    }
}

struct WindWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AppConfig.widgetKind,
                               intent: WindConfigurationIntent.self,
                               provider: WindProvider()) { entry in
            WindWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Vent balise")
        .description("Vent live de la balise FFVL, au rythme des relevés (10 min).")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryCircular, .accessoryInline
        ])
    }
}

struct WindWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WindEntry

    private var reading: WindReading { entry.snapshot.current }
    private var color: Color { WindPalette.color(kmh: reading.averageKmh) }

    var body: some View {
        switch family {
        case .systemSmall: small
        case .systemMedium: medium
        case .systemLarge: large
        case .accessoryRectangular: rectangular
        case .accessoryCircular: circular
        default: inline
        }
    }

    // MARK: Écran d'accueil

    private var small: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                WindArrow(degrees: reading.directionDegrees, color: color)
                    .frame(width: 13, height: 13)
                Text(reading.compass).font(.caption2.weight(.bold)).foregroundStyle(color)
                Spacer()
                Text(reading.date, style: .time)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(entry.unit.format(kmh: reading.averageKmh))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                Text(entry.unit.shortSymbol).font(.caption2).foregroundStyle(.secondary)
            }
            Text("raf. \(entry.unit.format(kmh: reading.gustKmh)) · mini \(entry.unit.format(kmh: reading.minKmh))")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            WindSparkline(values: sparkValues, color: color)
                .frame(height: 26)
            Text(entry.snapshot.baliseName)
                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private var medium: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    WindArrow(degrees: reading.directionDegrees, color: color)
                        .frame(width: 14, height: 14)
                    Text(reading.directionText).font(.caption.weight(.bold)).foregroundStyle(color)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(entry.unit.format(kmh: reading.averageKmh))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.6)
                    Text(entry.unit.shortSymbol).font(.caption2).foregroundStyle(.secondary)
                }
                Text("raf. \(entry.unit.format(kmh: reading.gustKmh))")
                    .font(.caption2).foregroundStyle(.orange)
                Spacer(minLength: 0)
                Text(reading.date, style: .time)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .frame(width: 112, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                WindChart(readings: entry.snapshot.window(hours: entry.windowHours),
                          unit: entry.unit, compact: true)
                Text(entry.snapshot.baliseName)
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
    }

    private var large: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.snapshot.baliseName).font(.headline)
                    HStack(spacing: 4) {
                        WindArrow(degrees: reading.directionDegrees, color: color)
                            .frame(width: 13, height: 13)
                        Text(reading.directionText).font(.caption.weight(.semibold)).foregroundStyle(color)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(entry.unit.format(kmh: reading.averageKmh))
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                        Text(entry.unit.shortSymbol).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("raf. \(entry.unit.format(kmh: reading.gustKmh)) · mini \(entry.unit.format(kmh: reading.minKmh))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            WindChart(readings: entry.snapshot.window(hours: entry.windowHours), unit: entry.unit)
            HStack {
                Text(reading.date, style: .time)
                Text("· relevé toutes les 10 min")
                Spacer()
                if let temp = reading.temperature { Text("\(Int(temp))°") }
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Écran verrouillé

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                WindArrow(degrees: reading.directionDegrees)
                    .frame(width: 10, height: 10)
                Text(reading.compass).font(.caption2.weight(.bold))
                Text(reading.date, style: .time)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(entry.unit.format(kmh: reading.averageKmh))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text(entry.unit.shortSymbol).font(.system(size: 10))
                Text("raf \(entry.unit.format(kmh: reading.gustKmh))").font(.system(size: 11))
            }
            WindSparkline(values: sparkValues, color: .primary)
                .frame(height: 12)
        }
    }

    private var circular: some View {
        Gauge(value: min(reading.averageKmh ?? 0, 60), in: 0...60) {
            WindArrow(degrees: reading.directionDegrees).frame(width: 8, height: 8)
        } currentValueLabel: {
            Text(entry.unit.format(kmh: reading.averageKmh))
                .font(.system(size: 16, weight: .bold, design: .rounded))
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var inline: some View {
        Text("\(reading.compass) \(entry.unit.format(kmh: reading.averageKmh))/\(entry.unit.format(kmh: reading.gustKmh)) \(entry.unit.shortSymbol)")
    }

    private var sparkValues: [Double] {
        let values = entry.snapshot.window(hours: 3).compactMap(\.averageKmh)
        return values.count > 1 ? values : [0, reading.averageKmh ?? 0]
    }
}
