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
            }
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

    private func thresholdRow(value: Binding<Double>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Seuil")
                Spacer()
                Text("\(unit.format(kmh: value.wrappedValue)) \(unit.symbol)")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            Slider(value: value, in: 2...70, step: 1)
                .tint(tint)
        }
    }
}
