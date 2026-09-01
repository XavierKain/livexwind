import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity

/// Lien montre ↔ téléphone, pour changer de spot depuis l'Apple Watch.
///
/// Le miroir HTTPS que lit la montre est volontairement en lecture seule, et
/// l'API du serveur n'est joignable que par Tailscale. Plutôt que d'ouvrir un
/// point d'écriture public, la montre demande à l'iPhone : lui a déjà le droit
/// d'écrire, et c'est lui qui reste la source de vérité. iOS réveille l'app en
/// arrière-plan pour traiter le message.
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    /// Émise sur l'iPhone quand la montre demande un changement de spot.
    static let selectionRequested = Notification.Name("livexwind.selectionRequested")

    private var session: WCSession? {
        WCSession.isSupported() ? .default : nil
    }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    // MARK: Côté montre

    /// Demande à l'iPhone d'afficher une autre balise.
    /// `transferUserInfo` prend le relais si la montre est hors de portée : le
    /// message sera livré quand le téléphone redeviendra joignable.
    func requestSelection(baliseID: Int) async -> Bool {
        guard let session else { return false }
        let payload: [String: Any] = ["select": baliseID]

        if session.isReachable {
            return await withCheckedContinuation { continuation in
                session.sendMessage(payload, replyHandler: { _ in
                    continuation.resume(returning: true)
                }, errorHandler: { _ in
                    session.transferUserInfo(payload)
                    continuation.resume(returning: false)
                })
            }
        }
        session.transferUserInfo(payload)
        return false
    }

    // MARK: Côté téléphone

    private func handle(_ payload: [String: Any]) {
        guard let id = payload["select"] as? Int else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.selectionRequested,
                                            object: nil, userInfo: ["id": id])
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message)
        replyHandler(["ok": true])
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    // MARK: Cycle de vie exigé par WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {}

    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()   // réactive pour la montre suivante
    }
    #endif
}
#endif
