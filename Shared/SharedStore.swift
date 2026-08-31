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

    func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
