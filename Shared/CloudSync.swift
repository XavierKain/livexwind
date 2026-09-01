import Foundation

/// Sauvegarde des spots et des seuils dans iCloud.
///
/// On passe par le magasin clé-valeur d'iCloud plutôt que par un conteneur de
/// fichiers : le volume est minuscule (quelques kilo-octets) et il n'y a rien à
/// provisionner. Sans lui, désinstaller l'app fait perdre la liste de balises et
/// tous les seuils, qui ne vivent que dans les réglages locaux.
///
/// Arbitrage en cas de conflit : le plus récent gagne, comparé sur un horodatage
/// écrit à chaque modification. Suffisant ici — on a un seul utilisateur et des
/// changements rares, pas d'édition simultanée sur deux appareils.
enum CloudSync {
    private static let payloadKey = "livexwind.payload"
    private static let localStampKey = "livexwind.localStamp"

    private struct Payload: Codable {
        var updatedAt: Date
        var catalog: BaliseCatalog
        var alerts: [String: AlertSettings]
        var unit: String
    }

    private static var cloud: NSUbiquitousKeyValueStore { .default }

    // MARK: Écriture

    /// Publie l'état local dans iCloud. Appelé à chaque changement de spots ou de seuils.
    static func push(catalog: BaliseCatalog, unit: WindUnit) {
        let alerts = Dictionary(uniqueKeysWithValues: catalog.balises.map {
            ($0.key, SharedStore.shared.alertSettings(for: $0.key))
        })
        let payload = Payload(updatedAt: .now, catalog: catalog, alerts: alerts, unit: unit.rawValue)
        guard let data = try? JSONEncoder().encode(payload) else { return }

        cloud.set(data, forKey: payloadKey)
        cloud.synchronize()
        UserDefaults.standard.set(payload.updatedAt, forKey: localStampKey)
    }

    // MARK: Lecture

    /// Adopte l'état d'iCloud s'il est plus récent que le nôtre.
    /// Renvoie le catalogue restauré, ou `nil` si le local fait déjà foi.
    @discardableResult
    static func adoptIfNewer() -> BaliseCatalog? {
        cloud.synchronize()
        guard let data = cloud.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              !payload.catalog.balises.isEmpty else { return nil }

        let localStamp = UserDefaults.standard.object(forKey: localStampKey) as? Date
        guard localStamp == nil || payload.updatedAt > localStamp! else { return nil }

        for (key, settings) in payload.alerts {
            SharedStore.shared.setAlertSettings(settings, for: key)
        }
        if let unit = WindUnit(rawValue: payload.unit) {
            SharedStore.shared.unit = unit
        }
        SharedStore.shared.catalog = payload.catalog
        UserDefaults.standard.set(payload.updatedAt, forKey: localStampKey)
        return payload.catalog
    }

    /// Prévient quand un autre appareil a modifié la liste.
    static func observe(_ onExternalChange: @escaping () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { _ in onExternalChange() }
    }
}
