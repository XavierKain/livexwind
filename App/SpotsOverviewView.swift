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
            // Une `List` plutôt qu'une pile : c'est ce qui apporte le glissement
            // pour supprimer. Retirer une balise passait jusqu'ici par l'écran
            // d'ajout, ce qui n'avait rien d'évident.
            List {
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
                    .listRowInsets(EdgeInsets(top: 4, leading: 14, bottom: 4, trailing: 14))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        if store.catalog.balises.count > 1 {
                            Button(role: .destructive) {
                                Task { await store.removeBalise(id: balise.id) }
                            } label: {
                                Label("Retirer", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
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
    private var isOffline: Bool { snapshot?.isOffline == true }
    private var color: Color {
        isOffline ? .secondary : WindPalette.color(kmh: reading?.averageKmh)
    }

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
                    if isOffline, let snapshot {
                        Image(systemName: "bolt.horizontal.circle")
                        Text(snapshot.offlineText)
                    } else {
                        Text(balise.provider.label)
                        if let date = reading?.date {
                            Text("·")
                            Text(date, style: .time)
                        }
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
                    .foregroundStyle(isOffline ? Color.secondary : Color.orange)
            }
            .frame(width: 78, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        // Hors ligne : toute la ligne s'estompe, y compris la mini-courbe.
        .opacity(isOffline ? 0.55 : 1)
        .background(.quaternary.opacity(isSelected ? 0.45 : 0.22),
                    in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? color.opacity(0.55) : .clear, lineWidth: 1.5)
        )
    }
}
