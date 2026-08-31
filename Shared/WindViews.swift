import SwiftUI
import Charts

// MARK: - Couleurs de force

enum WindPalette {
    /// Échelle pensée vol libre / kite : calme → volable → musclé → trop.
    static func color(kmh: Double?) -> Color {
        guard let kmh else { return .gray }
        switch kmh {
        case ..<8: return Color(red: 0.55, green: 0.60, blue: 0.66)
        case 8..<18: return Color(red: 0.20, green: 0.74, blue: 0.51)
        case 18..<28: return Color(red: 0.15, green: 0.62, blue: 0.90)
        case 28..<38: return Color(red: 0.98, green: 0.65, blue: 0.15)
        default: return Color(red: 0.92, green: 0.27, blue: 0.31)
        }
    }
}

// MARK: - Rose des vents

/// Flèche orientée « d'où vient le vent » (convention météo).
struct WindArrow: View {
    var degrees: Int?
    var color: Color = .primary

    var body: some View {
        Image(systemName: "location.north.fill")
            .resizable()
            .scaledToFit()
            .foregroundStyle(color)
            // 270° = vent d'ouest → la flèche pointe vers l'est (là où il va).
            .rotationEffect(.degrees(Double((degrees ?? 0) + 180)))
            .opacity(degrees == nil ? 0.25 : 1)
    }
}

struct CompassDial: View {
    var reading: WindReading
    var unit: WindUnit

    var body: some View {
        let color = WindPalette.color(kmh: reading.averageKmh)
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(1, (reading.averageKmh ?? 0) / 60))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))

            ForEach(["N", "E", "S", "O"].indices, id: \.self) { i in
                Text(["N", "E", "S", "O"][i])
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(y: -78)
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            // Marqueur posé sur le cercle au relèvement d'où vient le vent,
            // pointe tournée vers le centre.
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 15))
                .foregroundStyle(color)
                .offset(y: -70)
                .rotationEffect(.degrees(Double(reading.directionDegrees ?? 0)))
                .opacity(reading.directionDegrees == nil ? 0.2 : 1)

            VStack(spacing: 0) {
                Text(unit.format(kmh: reading.averageKmh))
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(unit.symbol)
                    .font(.caption).foregroundStyle(.secondary)
                Text(reading.directionText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.top, 4)
            }
        }
        .frame(width: 190, height: 190)
    }
}

// MARK: - Graphe

struct WindChart: View {
    var readings: [WindReading]
    var unit: WindUnit
    var showDirection: Bool = true
    var compact: Bool = false
    /// Active le curseur au doigt (app seulement — un widget ne reçoit pas de gestes).
    var interactive: Bool = false

    @State private var selected: WindReading?
    @State private var isScrubbing = false

    private func value(_ kmh: Double?) -> Double? {
        kmh.map { unit.convert(fromKmh: $0) }
    }

    var body: some View {
        Chart {
            ForEach(readings) { r in
                if let gust = value(r.gustKmh) {
                    AreaMark(x: .value("Heure", r.date), yStart: .value("min", value(r.minKmh) ?? 0),
                             yEnd: .value("raf", gust))
                        .foregroundStyle(.blue.opacity(0.12))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(readings) { r in
                if let gust = value(r.gustKmh) {
                    LineMark(x: .value("Heure", r.date), y: .value("Rafales", gust), series: .value("s", "raf"))
                        .foregroundStyle(Color.orange.opacity(0.75))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                        .interpolationMethod(.monotone)
                }
            }
            ForEach(readings) { r in
                if let avg = value(r.averageKmh) {
                    LineMark(x: .value("Heure", r.date), y: .value("Moyen", avg), series: .value("s", "moy"))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if showDirection {
                ForEach(readings) { r in
                    if let avg = value(r.averageKmh), r.directionDegrees != nil {
                        PointMark(x: .value("Heure", r.date), y: .value("Moyen", avg))
                            .symbol {
                                WindArrow(degrees: r.directionDegrees,
                                          color: WindPalette.color(kmh: r.averageKmh))
                                    .frame(width: 9, height: 9)
                            }
                    }
                }
            }

            if let selected, let avg = value(selected.averageKmh) {
                RuleMark(x: .value("Heure", selected.date))
                    .foregroundStyle(.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, spacing: 2,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        callout(selected)
                    }
                PointMark(x: .value("Heure", selected.date), y: .value("Moyen", avg))
                    .symbolSize(90)
                    .foregroundStyle(WindPalette.color(kmh: selected.averageKmh))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v))").font(.caption2)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: compact ? 3 : 5)) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.12))
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartOverlay { proxy in
            if interactive {
                GeometryReader { geo in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        // simultaneousGesture : la ScrollView garde la main sur le
                        // geste vertical. On ne prend le curseur que si le doigt
                        // part clairement à l'horizontale, et on garde la main
                        // jusqu'au relâchement.
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 12)
                                .onChanged { drag in
                                    if !isScrubbing {
                                        guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                                        isScrubbing = true
                                    }
                                    guard let plot = proxy.plotFrame else { return }
                                    let x = drag.location.x - geo[plot].origin.x
                                    guard let date: Date = proxy.value(atX: x) else { return }
                                    selected = nearest(to: date)
                                }
                                .onEnded { _ in isScrubbing = false }
                        )
                }
            }
        }
    }

    private func nearest(to date: Date) -> WindReading? {
        readings.min { a, b in
            abs(a.date.timeIntervalSince(date)) < abs(b.date.timeIntervalSince(date))
        }
    }

    @ViewBuilder
    private func callout(_ reading: WindReading) -> some View {
        let color = WindPalette.color(kmh: reading.averageKmh)
        VStack(alignment: .leading, spacing: 1) {
            Text(reading.date, format: .dateTime.hour().minute())
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                WindArrow(degrees: reading.directionDegrees, color: color)
                    .frame(width: 10, height: 10)
                Text("\(unit.format(kmh: reading.averageKmh)) \(unit.shortSymbol)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
            }
            Text("raf. \(unit.format(kmh: reading.gustKmh)) · \(reading.compass)")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.35), lineWidth: 1))
    }
}

/// Mini-courbe sans axes pour widgets et Dynamic Island.
struct WindSparkline: View {
    var values: [Double]
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { geo in
            let points = values
            let maxV = max(points.max() ?? 1, 1)
            let minV = min(points.min() ?? 0, maxV - 1)
            Path { path in
                guard points.count > 1 else { return }
                for (i, v) in points.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(points.count - 1)
                    let ratio = (v - minV) / max(maxV - minV, 0.001)
                    let y = geo.size.height * (1 - CGFloat(ratio))
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}
