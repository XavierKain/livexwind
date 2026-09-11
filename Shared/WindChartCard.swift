import SwiftUI

// Réservé à iOS : le zoom au pincement n'existe pas sur watchOS, et la montre
// compile l'ensemble de Shared.
#if os(iOS)

/// Carte « Évolution » : paliers de fenêtre, zoom au pincement, curseur au doigt.
///
/// Partagée entre l'écran de la balise suivie et l'aperçu d'une balise touchée
/// sur la carte — les deux montrent exactement la même courbe, et la logique de
/// fenêtre n'existe qu'ici.
struct WindChartCard: View {
    var snapshot: WindSnapshot
    var unit: WindUnit

    /// Paliers proposés. Le quart d'heure et l'heure servent aux stations qui
    /// publient à la minute, où six heures écrasent tout le détail.
    private static let ranges: [Double] = [0.25, 1, 3, 6, 12, 24]
    private static let minWindow = 0.1     // 6 minutes
    private static let maxWindow = 48.0

    @State private var windowHours: Double = 6
    /// Valeur au début du pincement, pour que le zoom reste proportionnel.
    @State private var pinchAnchor: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Évolution").font(.headline)
                Text(windowLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }

            HStack(spacing: 4) {
                ForEach(Self.ranges, id: \.self) { hours in
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { windowHours = hours }
                    } label: {
                        Text(Self.shortLabel(hours))
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(abs(windowHours - hours) < 0.01
                                        ? Color.accentColor.opacity(0.28)
                                        : Color.gray.opacity(0.14),
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }

            WindChart(readings: snapshot.window(hours: windowHours),
                      unit: unit, interactive: true)
                .frame(height: 190)
                // Le pincement se fait à deux doigts : il ne gêne ni le curseur
                // (un doigt, horizontal) ni le défilement de la page.
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let anchor = pinchAnchor ?? windowHours
                            if pinchAnchor == nil { pinchAnchor = anchor }
                            windowHours = min(Self.maxWindow,
                                              max(Self.minWindow, anchor / value.magnification))
                        }
                        .onEnded { _ in pinchAnchor = nil }
                )

            HStack(spacing: 14) {
                legend(color: .accentColor, text: "Moyen")
                legend(color: .orange, text: "Rafales")
                Text("glisse ou pince la courbe").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
    }

    /// « 15 min », « 1 h », « 2 h 30 » — la fenêtre peut tomber entre deux
    /// paliers après un pincement.
    private var windowLabel: String {
        let minutes = Int((windowHours * 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest)"
    }

    private static func shortLabel(_ hours: Double) -> String {
        hours < 1 ? "\(Int(hours * 60)) min" : "\(Int(hours)) h"
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Les chiffres du relevé : mini, moyen, rafales, température.
struct WindMetricsRow: View {
    var reading: WindReading
    var unit: WindUnit
    var isOffline: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            metric("Mini", reading.minKmh, .secondary)
            metric("Moyen", reading.averageKmh,
                   isOffline ? .secondary : WindPalette.color(kmh: reading.averageKmh))
            metric("Rafales", reading.gustKmh, isOffline ? .secondary : .orange)
            if let temperature = reading.temperature {
                VStack(spacing: 2) {
                    Text("Temp.").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(temperature))°")
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func metric(_ title: String, _ value: Double?, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(unit.format(kmh: value))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }
}

#endif
