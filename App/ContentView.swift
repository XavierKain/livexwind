import SwiftUI
import Charts
import CoreLocation

struct ContentView: View {
    @ObservedObject var store: WindStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAlerts = false


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    // Grisé et estompé hors ligne : la valeur reste lisible mais
                    // ne peut plus être prise pour le vent du moment.
                    CompassDial(reading: store.snapshot.current, unit: store.unit,
                                isOffline: store.snapshot.isOffline)
                        .padding(.top, 4)
                    unitPicker
                    WindMetricsRow(reading: store.snapshot.current, unit: store.unit,
                                   isOffline: store.snapshot.isOffline)
                    WindChartCard(snapshot: store.snapshot, unit: store.unit)
                    alertsCard
                    if let coordinate = baliseCoordinate {
                        BaliseMapCard(balise: store.balise, coordinate: coordinate)
                    }
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

    /// La position n'est pas toujours publiée : le catalogue local peut être
    /// antérieur à son ajout, auquel cas le flux du serveur la fournit.
    private var baliseCoordinate: CLLocationCoordinate2D? {
        let latitude = store.balise.latitude ?? store.snapshot.latitude
        let longitude = store.balise.longitude ?? store.snapshot.longitude
        guard let latitude, let longitude,
              CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
              !(latitude == 0 && longitude == 0) else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    // MARK: Sections

    private var header: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.snapshot.isOffline ? Color.gray : Color.green)
                    .frame(width: 8, height: 8)
                Text(store.snapshot.isOffline
                     ? "Balise \(store.snapshot.offlineText)"
                     : "Relevé de \(time(store.snapshot.current.date))")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(store.snapshot.isOffline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                if store.isLoading {
                    ProgressView().controlSize(.mini).padding(.leading, 2)
                }
            }
            Text(store.snapshot.isOffline
                 ? "Dernier relevé à \(time(store.snapshot.current.date)) · cadence \(store.snapshot.cadenceText)"
                 : "Mise à jour \(store.nextUpdateText) · \(store.snapshot.cadenceText)")
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
