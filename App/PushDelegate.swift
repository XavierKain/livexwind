import UIKit
import UserNotifications

/// Récupère le token APNs de l'appareil et le donne au serveur, qui s'en sert
/// pour envoyer les alertes de seuil même quand l'app est fermée.
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.hexString
        Task {
            do {
                try await ServerClient.shared.registerDeviceToken(hex)
                SharedStore.shared.serverHandlesAlerts = true
            } catch {
                // Hors Tailscale : on retombe sur les notifications locales.
                SharedStore.shared.serverHandlesAlerts = false
            }
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        SharedStore.shared.serverHandlesAlerts = false
    }

    /// Affiche aussi les alertes quand l'app est au premier plan.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
