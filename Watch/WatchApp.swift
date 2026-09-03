import SwiftUI
import WidgetKit

@main
struct LiveXWindWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchWindView()
        }
    }
}

@MainActor
final class WatchWindStore: ObservableObject {
    @Published private(set) var snapshot: WindSnapshot = .placeholder()
    @Published private(set) var isLoading = false
    /// Suit l'iPhone : l'unité se règle là-bas, la montre s'aligne.
    @Published private(set) var unit: WindUnit = SharedStore.shared.unit

    init() {
        WatchLink.shared.activate()
    }

    func refresh() async {
        isLoading = true
        let reading = await WatchFeed.load()
        snapshot = reading.snapshot
        unit = reading.unit
        isLoading = false
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Écran principal + liste des spots, en deux pages qu'on feuillette
/// horizontalement — pas de défilement vertical à faire pour changer de spot.
struct WatchWindView: View {
    @StateObject private var store = WatchWindStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            WatchMainView(store: store)
                .tag(0)
            NavigationStack {
                WatchSpotsView(store: store, page: $page)
            }
            .tag(1)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .task { await store.refresh() }
        .onChange(of: scenePhase) { _, phase in
            // Un `.task` ne se rejoue pas quand on rouvre l'app depuis une
            // complication : la vue existait déjà, elle affichait le dernier
            // relevé chargé avant la mise en arrière-plan. On force donc un
            // rafraîchissement à chaque retour au premier plan.
            if phase == .active {
                Task { await store.refresh() }
            }
        }
    }
}

/// Page 1 : le relevé du spot sélectionné, sans rien à faire défiler.
struct WatchMainView: View {
    @ObservedObject var store: WatchWindStore

    private var reading: WindReading { store.snapshot.current }
    private var color: Color { WindPalette.color(kmh: reading.averageKmh) }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(store.snapshot.baliseName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if store.isLoading {
                    ProgressView().controlSize(.mini)
                }
            }

            Spacer(minLength: 0)

            HStack(alignment: .center, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(store.unit.format(kmh: reading.averageKmh))
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Text(store.unit.shortSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                WindArrow(degrees: reading.directionDegrees, color: color)
                    .frame(width: 34, height: 34)
            }
            Text(reading.directionText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(color)

            Text("raf. \(store.unit.format(kmh: reading.gustKmh)) \(store.unit.shortSymbol)")
                .font(.system(size: 12))
                .foregroundStyle(.orange)

            Spacer(minLength: 0)

            HStack(spacing: 3) {
                Text(reading.date, style: .time)
                Text("·")
                Text(store.snapshot.cadenceText)
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }
}
