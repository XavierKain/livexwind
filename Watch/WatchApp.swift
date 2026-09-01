import SwiftUI
import WidgetKit

@main
struct LiveXWindWatchApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchWindView()
            }
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

struct WatchWindView: View {
    @StateObject private var store = WatchWindStore()

    private var reading: WindReading { store.snapshot.current }
    private var color: Color { WindPalette.color(kmh: reading.averageKmh) }

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    WindArrow(degrees: reading.directionDegrees, color: color)
                        .frame(width: 13, height: 13)
                    Text(reading.directionText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(color)
                    Spacer()
                    if store.isLoading {
                        ProgressView().controlSize(.mini)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(store.unit.format(kmh: reading.averageKmh))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(color)
                    Text(store.unit.shortSymbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text("raf. \(store.unit.format(kmh: reading.gustKmh)) \(store.unit.shortSymbol)")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                WindSparkline(values: store.snapshot.window(hours: 3).compactMap(\.averageKmh),
                              color: color)
                    .frame(height: 30)

                HStack {
                    Text(reading.date, style: .time)
                    Text("·")
                    Text(store.snapshot.cadenceText)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                NavigationLink {
                    WatchSpotsView(store: store)
                } label: {
                    Label("Changer de spot", systemImage: "list.bullet")
                        .font(.caption2)
                }
            }
            .padding(.horizontal, 4)
        }
        .navigationTitle(store.snapshot.baliseName)
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }
}
