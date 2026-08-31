import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Cache local du dernier relevé + préférence d'unité de l'app.
/// Chaque process (app / extension widget) garde son propre cache : le widget
/// interroge la balise directement, le cache ne sert que de secours hors-ligne.
struct SharedStore {
    static let shared = SharedStore()

    private let defaults: UserDefaults
    private let snapshotKey = "wind.snapshot"
    private let unitKey = "wind.unit"
    private let alertSettingsKey = "wind.alerts.settings"
    private let alertStateKey = "wind.alerts.state"
    private let serverURLKey = "wind.server.url"
    private let serverAlertsKey = "wind.server.handlesAlerts"
    private let catalogKey = "wind.balises"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var unit: WindUnit {
        get { WindUnit(rawValue: defaults.string(forKey: unitKey) ?? "") ?? .kmh }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: unitKey)
            reloadWidgets()
        }
    }

    // MARK: Alertes de seuil — un réglage par balise

    /// Les conditions ne se ressemblent pas d'un spot à l'autre : 39 km/h d'est
    /// à Tarifa n'a rien à voir avec ce qu'on attend au Pilat. Chaque balise a
    /// donc ses propres seuils, sa propre direction attendue et ses verrous.
    func alertSettings(for key: String) -> AlertSettings {
        migrateLegacyAlertsIfNeeded(to: key)
        guard let data = defaults.data(forKey: "\(alertSettingsKey).\(key)"),
              let value = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return .default }
        return value
    }

    func setAlertSettings(_ settings: AlertSettings, for key: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: "\(alertSettingsKey).\(key)")
    }

    func alertState(for key: String) -> AlertState {
        guard let data = defaults.data(forKey: "\(alertStateKey).\(key)"),
              let value = try? JSONDecoder().decode(AlertState.self, from: data) else { return .empty }
        return value
    }

    func setAlertState(_ state: AlertState, for key: String) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: "\(alertStateKey).\(key)")
    }

    /// Les réglages d'avant le multi-balises étaient globaux : on les attribue
    /// à la balise affichée au moment de la migration, puis on les efface.
    private func migrateLegacyAlertsIfNeeded(to key: String) {
        guard let legacy = defaults.data(forKey: alertSettingsKey) else { return }
        if defaults.data(forKey: "\(alertSettingsKey).\(key)") == nil {
            defaults.set(legacy, forKey: "\(alertSettingsKey).\(key)")
        }
        defaults.removeObject(forKey: alertSettingsKey)
        defaults.removeObject(forKey: alertStateKey)
    }

    /// Balises pour lesquelles au moins une alerte est active.
    func balisesWithAlerts(in catalog: BaliseCatalog) -> [Balise] {
        catalog.balises.filter { alertSettings(for: $0.key).enabled }
    }

    // MARK: Balises suivies

    var catalog: BaliseCatalog {
        get {
            guard let data = defaults.data(forKey: catalogKey),
                  let value = try? JSONDecoder().decode(BaliseCatalog.self, from: data),
                  !value.balises.isEmpty else { return .default }
            return value
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: catalogKey)
            reloadWidgets()
        }
    }

    /// Un instantané par balise : changer de spot n'efface pas la courbe de l'autre.
    func loadSnapshot(key: String) -> WindSnapshot? {
        guard let data = defaults.data(forKey: "\(snapshotKey).\(key)") else { return nil }
        return try? JSONDecoder().decode(WindSnapshot.self, from: data)
    }

    func save(snapshot: WindSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: "\(snapshotKey).\(snapshot.baliseKey)")
    }

    // MARK: Serveur de push

    var serverURL: String {
        get { defaults.string(forKey: serverURLKey) ?? AppConfig.defaultServerURL }
        nonmutating set { defaults.set(newValue, forKey: serverURLKey) }
    }

    /// Vrai quand le serveur a bien pris les seuils : l'app arrête alors de
    /// notifier localement pour éviter les doublons.
    var serverHandlesAlerts: Bool {
        get { defaults.bool(forKey: serverAlertsKey) }
        nonmutating set { defaults.set(newValue, forKey: serverAlertsKey) }
    }

    func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
