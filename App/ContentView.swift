import SwiftUI
import Charts

struct ContentView: View {
    @StateObject private var store = WindStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var range: HistoryRange = .sixHours

    enum HistoryRange: Double, CaseIterable, Identifiable {
        case threeHours = 3, sixHours = 6, twelveHours = 12, day = 24
        var id: Double { rawValue }
        var label: String { "\(Int(rawValue)) h" }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    CompassDial(reading: store.snapshot.current, unit: store.unit)
                        .padding(.top, 4)
                    unitPicker
                    metrics
                    chartCard
                    liveActivityCard
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .navigationTitle(store.snapshot.baliseName)
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: AppConfig.pageURL) {
                        Image(systemName: "safari")
                    }
                }
            }
        }
        .task {
            store.liveActivity.refreshActiveState()
            store.startAutoRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                store.startAutoRefresh()
                store.liveActivity.refreshActiveState()
            default:
                store.stopAutoRefresh()
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.snapshot.isStale ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(store.snapshot.isStale ? "Relevé en retard" : "Relevé de \(time(store.snapshot.current.date))")
                    .font(.subheadline.weight(.medium))
                if store.isLoading {
                    ProgressView().controlSize(.mini).padding(.leading, 2)
                }
            }
            Text("Mise à jour \(store.nextUpdateText) · toutes les 10 min")
                .font(.caption).foregroundStyle(.secondary)
            if let error = store.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.top, 6)
    }

    private var unitPicker: some View {
        Picker("Unité", selection: $store.unit) {
            Text("km/h").tag(WindUnit.kmh)
            Text("nœuds").tag(WindUnit.knots)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
    }

    private var metrics: some View {
        HStack(spacing: 10) {
            metric("Mini", store.snapshot.current.minKmh, .secondary)
            metric("Moyen", store.snapshot.current.averageKmh, WindPalette.color(kmh: store.snapshot.current.averageKmh))
            metric("Rafales", store.snapshot.current.gustKmh, .orange)
            if let temp = store.snapshot.current.temperature {
                VStack(spacing: 2) {
                    Text("Temp.").font(.caption2).foregroundStyle(.secondary)
                    Text("\(Int(temp))°")
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
            Text(store.unit.format(kmh: value))
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Évolution").font(.headline)
                Spacer()
                Picker("Fenêtre", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            WindChart(readings: store.snapshot.window(hours: range.rawValue), unit: store.unit)
                .frame(height: 190)
            HStack(spacing: 14) {
                legend(color: .accentColor, text: "Moyen")
                legend(color: .orange, text: "Rafales")
                Label("flèche = sens du vent", systemImage: "location.north.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(text).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activité en direct").font(.headline)
            Text("Affiche le vent sur l'écran verrouillé et l'île dynamique. Elle se rafraîchit à chaque nouveau relevé quand l'app tourne, et à chaque réveil en arrière-plan.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button {
                    Task {
                        if store.liveActivity.isActive {
                            await store.liveActivity.stop()
                        } else {
                            await store.liveActivity.start(snapshot: store.snapshot, unit: store.unit)
                        }
                    }
                } label: {
                    Label(store.liveActivity.isActive ? "Arrêter" : "Activer",
                          systemImage: store.liveActivity.isActive ? "stop.circle" : "play.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(store.liveActivity.isActive ? .red : .accentColor)
            }
            if let error = store.liveActivity.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
    }

    private var footer: some View {
        VStack(spacing: 3) {
            if let alt = store.snapshot.altitude {
                Text("Balise FFVL #\(store.snapshot.baliseID) · \(alt) m")
            } else {
                Text("Balise FFVL #\(store.snapshot.baliseID)")
            }
            Text("Données balisemeteo.com / FFVL")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
