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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadSnapshot() -> WindSnapshot? {
        guard let data = defaults.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WindSnapshot.self, from: data)
    }

    func save(snapshot: WindSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: snapshotKey)
    }

    var unit: WindUnit {
        get { WindUnit(rawValue: defaults.string(forKey: unitKey) ?? "") ?? .kmh }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: unitKey)
            reloadWidgets()
        }
    }

    // MARK: Alertes de seuil

    var alertSettings: AlertSettings {
        get {
            guard let data = defaults.data(forKey: alertSettingsKey),
                  let value = try? JSONDecoder().decode(AlertSettings.self, from: data) else { return .default }
            return value
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: alertSettingsKey)
        }
    }

    var alertState: AlertState {
        get {
            guard let data = defaults.data(forKey: alertStateKey),
                  let value = try? JSONDecoder().decode(AlertState.self, from: data) else { return .empty }
            return value
        }
        nonmutating set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: alertStateKey)
        }
    }

    func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
