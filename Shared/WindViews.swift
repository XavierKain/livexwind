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
                    .offset(y: -82)
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            // Marqueur au relèvement d'où vient le vent, pointe tournée vers le
            // centre. Il est nettement rentré vers l'intérieur : posé contre
            // l'anneau, il chevauchait les lettres de la rose.
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 26))
                .foregroundStyle(color)
                .offset(y: -60)
                .rotationEffect(.degrees(Double(reading.directionDegrees ?? 0)))
                .opacity(reading.directionDegrees == nil ? 0.2 : 1)

            VStack(spacing: 0) {
                Text(unit.format(kmh: reading.averageKmh))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
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
        .frame(width: 200, height: 200)
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
    @State private var dismissTask: Task<Void, Never>?

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
            #if os(iOS)
            if interactive {
                GeometryReader { geo in
                    // Reconnaisseur UIKit : il ne démarre que sur un geste
                    // horizontal, donc le défilement vertical de la page passe.
                    HorizontalPanArea { point in
                        dismissTask?.cancel()
                        dismissTask = nil
                        guard let plot = proxy.plotFrame else { return }
                        let x = point.x - geo[plot].origin.x
                        guard let date: Date = proxy.value(atX: x) else { return }
                        selected = nearest(to: date)
                    } onEnd: {
                        scheduleDismiss()
                    }
                }
            }
            #endif
        }
    }

    /// La bulle recouvre les réglages au-dessus du graphe : on la laisse le
    /// temps de lire la valeur, puis elle s'efface d'elle-même.
    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { selected = nil }
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

// MARK: - Secteur de direction

/// Aperçu du secteur d'alerte : l'arc coloré est la fenêtre attendue, la flèche
/// montre d'où vient le vent en ce moment.
struct DirectionSectorView: View {
    var center: Int
    var spread: Int
    var current: Int?

    var body: some View {
        let inSector = current.map { bearing -> Bool in
            var delta = abs(bearing - center) % 360
            if delta > 180 { delta = 360 - delta }
            return delta <= spread
        } ?? false

        ZStack {
            Circle().stroke(.quaternary, lineWidth: 8)

            Circle()
                .trim(from: 0, to: min(1, Double(spread * 2) / 360))
                .stroke(inSector ? Color.green : Color.accentColor,
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                // -90° pour partir du nord, puis on centre l'arc sur le relèvement.
                .rotationEffect(.degrees(Double(center - spread) - 90))

            ForEach(["N", "E", "S", "O"].indices, id: \.self) { i in
                Text(["N", "E", "S", "O"][i])
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .offset(y: -42)
                    .rotationEffect(.degrees(Double(i) * 90))
            }

            if let current {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(inSector ? .green : .secondary)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(current)))
            }

            VStack(spacing: 0) {
                Text("\(center)°")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("± \(spread)°")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 104, height: 104)
    }
}
