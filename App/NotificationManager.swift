import Foundation
import UserNotifications

/// Alertes locales de seuil. Elles partent depuis l'app (au premier plan) et
/// depuis le réveil `BGAppRefreshTask` : iOS décide de la fréquence de ces réveils,
/// donc une alerte peut arriver au relevé suivant plutôt qu'à la minute près.
enum NotificationManager {
    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        default:
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func isAuthorized() async -> Bool {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional || status == .ephemeral
    }

    static func post(_ event: AlertEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(
            identifier: "wind.\(event.kind.rawValue).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Évalue le relevé et notifie si un seuil vient d'être franchi.
    @discardableResult
    static func evaluateAndNotify(snapshot: WindSnapshot, unit: WindUnit) async -> AlertEvent? {
        let store = SharedStore.shared
        let (event, newState) = AlertEngine.evaluate(
            reading: snapshot.current,
            settings: store.alertSettings,
            state: store.alertState,
            unit: unit
        )
        store.alertState = newState
        guard let event, await isAuthorized() else { return nil }
        await post(event)
        return event
    }
}
