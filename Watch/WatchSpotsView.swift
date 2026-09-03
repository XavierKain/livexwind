import SwiftUI

/// Liste des spots sur la montre.
///
/// La liste et les relevés viennent du miroir public en un seul fichier ; le
/// changement de spot passe par l'iPhone, qui reste seul à écrire côté serveur.
struct WatchSpotsView: View {
    @ObservedObject var store: WatchWindStore
    /// Revient sur l'écran principal une fois le nouveau spot confirmé —
    /// remplace le `dismiss()` d'une navigation poussée, puisque les deux
    /// écrans sont désormais deux pages d'un même `TabView`.
    @Binding var page: Int

    @State private var spots: [WatchFeed.Spot] = []
    @State private var isLoading = true
    @State private var pending: Int?
    @State private var message: String?

    var body: some View {
        List {
            if isLoading && spots.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Chargement…").foregroundStyle(.secondary)
                }
            }

            ForEach(spots, id: \.key) { spot in
                Button {
                    select(spot)
                } label: {
                    row(spot)
                }
            }

            if let message {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Spots")
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ spot: WatchFeed.Spot) -> some View {
        let color = WindPalette.color(kmh: spot.current?.avg)
        return HStack(spacing: 8) {
            WindArrow(degrees: spot.current?.dir, color: color)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(spot.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("raf. \(store.unit.format(kmh: spot.current?.gust))")
                    .font(.system(size: 10)).foregroundStyle(.orange)
            }

            Spacer(minLength: 2)

            if pending == spot.id {
                ProgressView().controlSize(.mini)
            } else {
                Text(store.unit.format(kmh: spot.current?.avg))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
        }
    }

    private func load() async {
        isLoading = true
        spots = await WatchFeed.spots()
        isLoading = false
    }

    private func select(_ spot: WatchFeed.Spot) {
        pending = spot.id
        message = nil
        Task {
            let delivered = await WatchLink.shared.requestSelection(baliseID: spot.id)
            if delivered {
                // On attend que le pointeur publié désigne bien ce spot, sinon
                // on rechargerait l'ancien et la montre afficherait le mauvais.
                if await WatchFeed.waitForSelection(id: spot.id) {
                    await store.refresh()
                    withAnimation { page = 0 }
                } else {
                    message = "L'iPhone n'a pas encore appliqué le changement."
                }
            } else {
                message = "iPhone hors de portée — le changement sera appliqué dès qu'il revient."
            }
            pending = nil
        }
    }
}
