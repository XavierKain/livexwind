import SwiftUI

/// Vue d'ensemble : toutes les balises suivies, avec leur vent du moment.
///
/// Une ligne par spot, assez compacte pour en voir six sans faire défiler.
/// Toucher une ligne bascule dessus et ouvre le détail.
struct SpotsOverviewView: View {
    @ObservedObject var store: WindStore
    var onSelect: () -> Void

    @State private var showBalises = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.catalog.balises) { balise in
                        Button {
                            Task {
                                await store.select(baliseID: balise.id)
                                onSelect()
                            }
                        } label: {
                            SpotRow(balise: balise,
                                    snapshot: store.overview[balise.key],
                                    unit: store.unit,
                                    isSelected: balise.id == store.catalog.selectedID,
                                    hasAlerts: store.alertBadge(for: balise))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 20)
            }
            .navigationTitle("Mes spots")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refreshOverview(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showBalises = true
                    } label: {
                        Label("Gérer", systemImage: "plus.circle")
                    }
                }
            }
            .sheet(isPresented: $showBalises) {
                BalisesView(store: store)
            }
            .overlay {
                if store.catalog.balises.count == 1 && store.overview.isEmpty {
                    ProgressView()
                }
            }
        }
        .task { await store.refreshOverview() }
    }
}

/// Une ligne de la vue d'ensemble : direction, force, rafales, mini-courbe.
private struct SpotRow: View {
    let balise: Balise
    let snapshot: WindSnapshot?
    let unit: WindUnit
    let isSelected: Bool
    let hasAlerts: Bool

    private var reading: WindReading? { snapshot?.current }
    private var color: Color { WindPalette.color(kmh: reading?.averageKmh) }

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 2) {
                WindArrow(degrees: reading?.directionDegrees, color: color)
                    .frame(width: 22, height: 22)
                Text(reading?.compass ?? "—")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(balise.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if hasAlerts {
                        Image(systemName: "bell.fill").foregroundStyle(.orange)
                    }
                    Text(balise.provider.label)
                    if let date = reading?.date {
                        Text("·")
                        Text(date, style: .time)
                    }
                    if snapshot?.isStale == true {
                        Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let history = snapshot?.window(hours: 6), history.count > 1 {
                WindSparkline(values: history.compactMap(\.averageKmh), color: color)
                    .frame(width: 52, height: 26)
            }

            VStack(alignment: .trailing, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(unit.format(kmh: reading?.averageKmh))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Text(unit.shortSymbol)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Text("raf. \(unit.format(kmh: reading?.gustKmh))")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(isSelected ? 0.45 : 0.22),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? color.opacity(0.55) : .clear, lineWidth: 1.5)
        )
    }
}
