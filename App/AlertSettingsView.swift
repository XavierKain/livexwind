import SwiftUI

struct AlertSettingsView: View {
    @ObservedObject var store: WindStore
    @Environment(\.dismiss) private var dismiss

    private var unit: WindUnit { store.unit }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Alertes de seuil", isOn: Binding(
                        get: { store.alerts.enabled },
                        set: { on in
                            if on {
                                Task { await store.enableAlerts() }
                            } else {
                                store.alerts.enabled = false
                            }
                        }
                    ))
                    if store.alerts.enabled && !store.notificationsAuthorized {
                        Label("Notifications refusées — active-les dans Réglages > LiveXWind",
                              systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Picker("Basé sur", selection: $store.alerts.useGusts) {
                        Text("Vent moyen").tag(false)
                        Text("Rafales").tag(true)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Une alerte part au moment où le seuil est franchi, pas à chaque relevé au-dessus.")
                }

                Section("Vent fort") {
                    Toggle("Me prévenir quand ça monte", isOn: $store.alerts.upperEnabled)
                    if store.alerts.upperEnabled {
                        thresholdRow(value: $store.alerts.upperKmh, tint: .orange)
                    }
                }

                Section("Vent faible") {
                    Toggle("Me prévenir quand ça tombe", isOn: $store.alerts.lowerEnabled)
                    if store.alerts.lowerEnabled {
                        thresholdRow(value: $store.alerts.lowerKmh, tint: .blue)
                    }
                }

                Section {
                    Toggle("Me prévenir quand le vent tourne", isOn: $store.alerts.directionEnabled)
                    if store.alerts.directionEnabled {
                        HStack(spacing: 16) {
                            DirectionSectorView(center: store.alerts.directionCenter,
                                                spread: store.alerts.directionSpread,
                                                current: store.snapshot.current.directionDegrees)
                            VStack(alignment: .leading, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Direction attendue").font(.caption).foregroundStyle(.secondary)
                                    Slider(value: Binding(
                                        get: { Double(store.alerts.directionCenter) },
                                        set: { store.alerts.directionCenter = Int($0) }
                                    ), in: 0...355, step: 5)
                                }
                                Picker("Ouverture", selection: $store.alerts.directionSpread) {
                                    Text("± 22°").tag(22)
                                    Text("± 45°").tag(45)
                                    Text("± 67°").tag(67)
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("Direction")
                } footer: {
                    Text("Pratique quand tu attends une bascule : l'alerte part au moment où le vent entre dans le secteur, pas tant qu'il y reste.")
                }

                Section {
                    Stepper("À partir de \(store.alerts.startHour) h",
                            value: $store.alerts.startHour, in: 0...23)
                    Stepper("Jusqu'à \(store.alerts.endHour) h",
                            value: $store.alerts.endHour, in: 0...23)
                    Stepper("Pause de \(store.alerts.cooldownMinutes) min entre 2 alertes",
                            value: $store.alerts.cooldownMinutes, in: 10...240, step: 5)
                } header: {
                    Text("Quand")
                } footer: {
                    Text("Les alertes sont évaluées à chaque relevé lu par l'app, y compris lors des réveils en arrière-plan — iOS en fixe la cadence, une alerte peut donc arriver au relevé suivant.")
                }

                Section {
                    TextField("http://100.117.213.59:7110", text: $store.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    HStack {
                        Text("État")
                        Spacer()
                        switch store.serverReachable {
                        case .some(true): Label("joignable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .some(false): Label("injoignable", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        case nil: Text("—").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    Button("Tester la connexion") { Task { await store.checkServer() } }
                } header: {
                    Text("Serveur de push")
                } footer: {
                    Text("Quand le serveur répond, c'est lui qui envoie les alertes par APNs et qui met à jour l'activité en direct — l'app n'a pas besoin d'être ouverte. Hors Tailscale, l'app repasse en notifications locales.")
                }
            }
            .safeAreaInset(edge: .bottom) { EmptyView() }
            .navigationTitle("Alertes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .task { await store.refreshNotificationStatus() }
        }
    }

    /// Le seuil est stocké en km/h mais réglé dans l'unité affichée : un cran du
    /// curseur = 1 km/h ou 1 nœud selon le réglage, jamais un mélange des deux.
    private func thresholdRow(value: Binding<Double>, tint: Color) -> some View {
        let shown = Binding<Double>(
            get: { (unit.convert(fromKmh: value.wrappedValue) * 10).rounded() / 10 },
            set: { value.wrappedValue = unit.toKmh($0) }
        )
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Seuil")
                Spacer()
                Text("\(Int(shown.wrappedValue.rounded())) \(unit.symbol)")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            Slider(value: shown, in: unit.thresholdRange, step: 1)
                .tint(tint)
        }
    }
}
