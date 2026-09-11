import SwiftUI
import CoreLocation

/// Page d'une balise qu'on ne suit pas (encore).
///
/// Même contenu que l'écran d'une balise favorite — cadran, chiffres, courbe,
/// position — mais en lecture seule : pas d'alertes ni d'activité en direct,
/// qui n'ont de sens que sur une balise suivie.
struct BalisePreviewView: View {
    let balise: Balise
    @ObservedObject var store: WindStore

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: WindSnapshot?
    @State private var isLoading = true
    @State private var isAdding = false

    private var alreadyTracked: Bool {
        store.catalog.balises.contains { $0.key == balise.key }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let snapshot {
                        entete(snapshot)
                        CompassDial(reading: snapshot.current, unit: store.unit,
                                    isOffline: snapshot.isOffline)
                        WindMetricsRow(reading: snapshot.current, unit: store.unit,
                                       isOffline: snapshot.isOffline)
                        if snapshot.history.count > 1 {
                            WindChartCard(snapshot: snapshot, unit: store.unit)
                        }
                        if let coordinate = coordinate(snapshot) {
                            BaliseMapCard(balise: balise, coordinate: coordinate)
                        }
                        ajout
                        pied(snapshot)
                    } else if isLoading {
                        ProgressView("Relevé en cours…")
                            .padding(.top, 60)
                    } else {
                        Label("Relevé indisponible pour cette balise",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .padding(.top, 60)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .navigationTitle(balise.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: balise.pageURL) {
                        Image(systemName: "safari")
                    }
                }
            }
            .refreshable { await load() }
        }
        .task { await load() }
    }

    // MARK: Pièces

    private func entete(_ snapshot: WindSnapshot) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(snapshot.isOffline ? Color.gray : Color.green)
                    .frame(width: 8, height: 8)
                Text(snapshot.isOffline
                     ? "Balise \(snapshot.offlineText)"
                     : "Relevé de \(snapshot.current.date.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(snapshot.isOffline ? .secondary : .primary)
            }
            Text("\(balise.provider.label) · \(snapshot.cadenceText)")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var ajout: some View {
        Button {
            isAdding = true
            Task {
                _ = await store.addBalise(balise)
                isAdding = false
                dismiss()
            }
        } label: {
            Label(alreadyTracked ? "Déjà dans mes spots" : "Ajouter à mes spots",
                  systemImage: alreadyTracked ? "checkmark.circle.fill" : "plus.circle.fill")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .disabled(alreadyTracked || isAdding)
    }

    private func pied(_ snapshot: WindSnapshot) -> some View {
        VStack(spacing: 3) {
            Text(balise.subtitle)
            Text("Données \(balise.provider.label)")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func coordinate(_ snapshot: WindSnapshot) -> CLLocationCoordinate2D? {
        guard let latitude = balise.latitude ?? snapshot.latitude,
              let longitude = balise.longitude ?? snapshot.longitude,
              !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func load() async {
        isLoading = true
        let loaded = await BaliseClient(balise: balise).loadSnapshot()
        snapshot = loaded.current.averageKmh == nil && loaded.history.isEmpty ? nil : loaded
        isLoading = false
    }
}
