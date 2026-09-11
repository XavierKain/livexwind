import ActivityKit
import WidgetKit
import SwiftUI

struct WindLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WindActivityAttributes.self) { context in
            LiveActivityContent(context: context)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let unit = state.unit
            let color = WindPalette.color(kmh: state.averageKmh)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("moyen").font(.system(size: 10)).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(unit.format(kmh: state.averageKmh))
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(color)
                            Text(unit.shortSymbol).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("rafales").font(.system(size: 10)).foregroundStyle(.secondary)
                        Text("\(unit.format(kmh: state.gustKmh)) \(unit.shortSymbol)")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 4) {
                        WindArrow(degrees: state.directionDegrees, color: color)
                            .frame(width: 13, height: 13)
                        Text("\(state.directionLabel) \(state.directionDegrees)°")
                            .font(.caption.weight(.bold))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        WindSparkline(values: state.trendKmh, color: color)
                            .frame(height: 20)
                        Text(state.readingDate, style: .time)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                HStack(spacing: 2) {
                    WindArrow(degrees: state.directionDegrees, color: color)
                        .frame(width: 10, height: 10)
                    Text(unit.format(kmh: state.averageKmh))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
            } compactTrailing: {
                Text(unit.format(kmh: state.gustKmh))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
            } minimal: {
                // Emplacement partagé avec une autre activité : il n'y tient que
                // deux éléments. On garde la force et la direction — la rafale
                // ne rentre pas, et un chiffre sans direction ne dit rien.
                HStack(spacing: 1) {
                    Text(unit.format(kmh: state.averageKmh))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    WindArrow(degrees: state.directionDegrees, color: color)
                        .frame(width: 9, height: 9)
                }
            }
            .keylineTint(color)
            .widgetURL(AppConfig.pageURL(balise: context.attributes.baliseID))
        }
        // Sans ça, l'Apple Watch se rabat sur la vue compacte de l'île dynamique
        // et n'affiche presque rien dans la pile intelligente.
        .supplementalActivityFamilies([.small])
    }

}

/// Contenu de l'activité en direct, décliné selon l'endroit où il s'affiche :
/// pleine largeur sur l'écran verrouillé de l'iPhone, plus resserré dans la pile
/// intelligente de l'Apple Watch — mais avec les mêmes informations.
struct LiveActivityContent: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<WindActivityAttributes>

    private var state: WindActivityAttributes.ContentState { context.state }
    private var unit: WindUnit { state.unit }
    private var color: Color { WindPalette.color(kmh: state.averageKmh) }

    var body: some View {
        switch family {
        case .small: watch
        default: lockScreen
        }
    }

    private var entete: some View {
        HStack {
            if state.secondaries?.isEmpty == false {
                Text("1")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            Label(context.attributes.baliseName, systemImage: "wind")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Spacer()
            Text(state.readingDate, style: .time)
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var chiffres: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(unit.format(kmh: state.averageKmh))
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(unit.symbol).font(.caption).foregroundStyle(.secondary)
            }
            Text("rafales \(unit.format(kmh: state.gustKmh)) · mini \(unit.format(kmh: state.minKmh))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var boussole: some View {
        VStack(spacing: 0) {
            WindArrow(degrees: state.directionDegrees, color: color)
                .frame(width: 26, height: 26)
            Text(state.directionLabel)
                .font(.caption2.weight(.bold)).foregroundStyle(color)
        }
    }

    private var lockScreen: some View {
        VStack(spacing: 6) {
            entete
            HStack(alignment: .center, spacing: 14) {
                boussole
                chiffres
                Spacer()
                WindSparkline(values: state.trendKmh, color: color)
                    .frame(width: 74, height: 34)
            }
            secondaires
        }
        .padding(14)
    }

    /// Les balises d'appoint, sous la principale : voir qu'il y a 15 nœuds ici
    /// et 25 dix kilomètres plus loin se lit d'un coup d'œil.
    @ViewBuilder
    private var secondaires: some View {
        if let others = state.secondaries, !others.isEmpty {
            VStack(spacing: 3) {
                Divider().opacity(0.35)
                ForEach(Array(others.enumerated()), id: \.offset) { index, other in
                    ligneSecondaire(index: index + 2, other: other)
                }
            }
        }
    }

    private func ligneSecondaire(index: Int, other: WindActivityAttributes.SecondaryWind) -> some View {
        let teinte: Color = other.isOffline ? .secondary : WindPalette.color(kmh: other.averageKmh)
        return HStack(spacing: 6) {
            Text("\(index)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            WindArrow(degrees: other.isOffline ? nil : other.directionDegrees, color: teinte)
                .frame(width: 11, height: 11)
            Text(other.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            if other.isOffline {
                Text("hors ligne")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(unit.format(kmh: other.averageKmh))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(teinte)
                    Text("/ \(unit.format(kmh: other.gustKmh))")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    /// Pile intelligente de la montre.
    ///
    /// Pas de mini-courbe ici : la carte est trop basse, il n'en restait qu'un
    /// filet illisible. La place gagnée profite aux chiffres, qui sont ce qu'on
    /// vient lire au poignet.
    private var watch: some View {
        VStack(alignment: .leading, spacing: 5) {
            entete
            HStack(alignment: .center, spacing: 12) {
                boussole
                chiffres
                Spacer(minLength: 0)
            }
            if let others = state.secondaries, !others.isEmpty {
                // Une seule ligne, très condensée : la carte de la pile
                // intelligente est basse.
                Text(others.map { "\($0.name.prefix(9)) \(unit.format(kmh: $0.averageKmh))" }
                        .joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
