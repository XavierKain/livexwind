import SwiftUI

/// Deux onglets : la balise du moment en détail, et la vue d'ensemble des spots.
struct RootView: View {
    @StateObject private var store = WindStore()
    @State private var tab = Tab.detail

    enum Tab { case detail, spots, map }

    var body: some View {
        TabView(selection: $tab) {
            ContentView(store: store)
                .tabItem { Label("Balise", systemImage: "wind") }
                .tag(Tab.detail)

            SpotsOverviewView(store: store) { tab = .detail }
                .tabItem { Label("Mes spots", systemImage: "list.bullet") }
                .tag(Tab.spots)

            StationsMapView(store: store) { tab = .detail }
                .tabItem { Label("Carte", systemImage: "map") }
                .tag(Tab.map)
        }
    }
}
