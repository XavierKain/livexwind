import SwiftUI
import Charts

struct ContentView: View {
    @ObservedObject var store: WindStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var range: HistoryRange = .sixHours
    @State private var showAlerts = false

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
                    alertsCard
                    liveActivityCard
                    serverCard
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 30)
            }
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await store.refresh(force: true) }
            .toolbar {
                ToolbarItem(placement: .principal) { titre }
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: store.balise.pageURL) {
                        Image(systemName: "safari")
                    }
                }
            }
        }
        .sheet(isPresented: $showAlerts) { AlertSettingsView(store: store) }
        .task {
            await store.adoptCloudState()
            store.liveActivity.refreshActiveState()
            store.liveActivity.observePushToStartToken(unit: store.unit)
            await store.refreshNotificationStatus()
            await store.checkServer()
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


    private var titre: some View {
        VStack(spacing: 0) {
            Text(store.snapshot.baliseName)
                .font(.headline)
                .lineLimit(1)
            Text(store.balise.provider.label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
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
            Text("Mise à jour \(store.nextUpdateText) · \(store.snapshot.cadenceText)")
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
            WindChart(readings: store.snapshot.window(hours: range.rawValue), unit: store.unit, interactive: true)
                .frame(height: 190)
            HStack(spacing: 14) {
                legend(color: .accentColor, text: "Moyen")
                legend(color: .orange, text: "Rafales")
                Text("glisse le doigt sur la courbe").font(.caption2).foregroundStyle(.tertiary)
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


    private var alertsCard: some View {
        Button { showAlerts = true } label: {
            HStack(spacing: 12) {
                Image(systemName: store.alerts.enabled ? "bell.badge.fill" : "bell.slash")
                    .font(.title3)
                    .foregroundStyle(store.alerts.enabled ? Color.orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alertes de seuil").font(.headline).foregroundStyle(.primary)
                    Text(alertsSummary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private var alertsSummary: String {
        guard store.alerts.enabled else { return "Désactivées — touche pour définir un seuil" }
        let source = store.alerts.useGusts ? "rafales" : "vent moyen"
        var parts: [String] = []
        if store.alerts.upperEnabled {
            parts.append("≥ \(store.unit.format(kmh: store.alerts.upperKmh))")
        }
        if store.alerts.lowerEnabled {
            parts.append("≤ \(store.unit.format(kmh: store.alerts.lowerKmh))")
        }
        if parts.isEmpty { return "Aucun seuil actif" }
        return "\(source) \(parts.joined(separator: " · ")) \(store.unit.symbol) · \(store.alerts.startHour)h-\(store.alerts.endHour)h"
    }


    private var liveActivityBlurb: String {
        store.serverReachable == true
        ? "Affiche le vent sur l'écran verrouillé et l'île dynamique. Le serveur la met à jour par push à chaque relevé, même app fermée, et la relance tout seul quand iOS la coupe."
        : "Affiche le vent sur l'écran verrouillé et l'île dynamique. Serveur injoignable : elle ne se rafraîchira que quand l'app tourne ou lors des réveils décidés par iOS."
    }

    private var serverCard: some View {
        HStack(spacing: 12) {
            Image(systemName: serverIcon)
                .font(.title3)
                .foregroundStyle(serverColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Push serveur").font(.headline)
                Text(store.serverDetail ?? "Vérification…")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                Task { await store.checkServer() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 18))
    }

    private var serverIcon: String {
        switch store.serverReachable {
        case .some(true): return "antenna.radiowaves.left.and.right"
        case .some(false): return "antenna.radiowaves.left.and.right.slash"
        case nil: return "antenna.radiowaves.left.and.right"
        }
    }

    private var serverColor: Color {
        switch store.serverReachable {
        case .some(true): return .green
        case .some(false): return .orange
        case nil: return .secondary
        }
    }

    private var liveActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activité en direct").font(.headline)
            Text(liveActivityBlurb)
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
            Text("Balise FFVL \(store.balise.subtitle)")
            Text("Données balisemeteo.com / FFVL")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
