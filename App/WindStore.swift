import Combine
import Foundation
import SwiftUI
import WidgetKit

@MainActor
final class WindStore: ObservableObject {
    @Published private(set) var snapshot: WindSnapshot
    @Published private(set) var isLoading = false
    @Published var lastError: String?
    @Published var unit: WindUnit {
        didSet {
            guard unit != oldValue else { return }
            SharedStore.shared.unit = unit
            Task {
                // Le serveur construit ses push dans cette unité : il doit la connaître
                // tout de suite, sinon la Live Activity et les alertes restent en km/h.
                await syncAlertsWithServer()
                await liveActivity.push(snapshot: snapshot, unit: unit)
            }
        }
    }

    @Published var alerts: AlertSettings {
        didSet {
            guard alerts != oldValue else { return }
            SharedStore.shared.alertSettings = alerts
            Task { await syncAlertsWithServer() }
        }
    }
    @Published var serverURL: String {
        didSet {
            guard serverURL != oldValue else { return }
            SharedStore.shared.serverURL = serverURL
            Task { await checkServer() }
        }
    }
    @Published var serverReachable: Bool?
    @Published var serverDetail: String?
    @Published var notificationsAuthorized = false
    @Published var lastAlert: AlertEvent?

    let liveActivity = LiveActivityManager()
    private var timer: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let cached = SharedStore.shared.loadSnapshot()
        snapshot = cached ?? .placeholder
        unit = SharedStore.shared.unit
        alerts = SharedStore.shared.alertSettings
        serverURL = SharedStore.shared.serverURL

        // LiveActivityManager est un ObservableObject imbriqué : sans ce relais,
        // la vue ne se redessine pas quand son état change (bouton figé).
        liveActivity.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Le serveur garde les seuils de son côté pour pouvoir notifier app fermée.
    func syncAlertsWithServer() async {
        do {
            try await ServerClient.shared.pushAlertSettings(alerts, unit: unit)
            SharedStore.shared.serverHandlesAlerts = true
            serverReachable = true
        } catch {
            SharedStore.shared.serverHandlesAlerts = false
            serverReachable = false
        }
    }

    func checkServer() async {
        do {
            let health = try await ServerClient.shared.health()
            serverReachable = health.ok
            let activity = health.tokens?["update"] ?? 0
            serverDetail = health.apns_configured
                ? "APNs prêt · \(activity) activité(s) suivie(s)"
                : "Serveur joignable mais clé APNs absente"
            await syncAlertsWithServer()
        } catch {
            serverReachable = false
            serverDetail = "Injoignable — hors Tailscale ? Les mises à jour hors app passeront par iOS."
        }
    }

    func refreshNotificationStatus() async {
        notificationsAuthorized = await NotificationManager.isAuthorized()
    }

    func enableAlerts() async {
        let granted = await NotificationManager.requestAuthorization()
        notificationsAuthorized = granted
        alerts.enabled = granted
    }

    var nextUpdateText: String {
        let target = snapshot.nextExpectedUpdate
        let seconds = max(0, Int(target.timeIntervalSinceNow))
        return seconds < 60 ? "dans \(seconds) s" : "dans \(seconds / 60) min"
    }

    func refresh(force: Bool = false) async {
        if isLoading && !force { return }
        isLoading = true
        defer { isLoading = false }

        let fresh = await BaliseClient.shared.loadSnapshot()
        let previous = snapshot
        snapshot = fresh
        lastError = fresh.current.averageKmh == nil ? "Relevé indisponible" : nil
        WidgetCenter.shared.reloadAllTimelines()

        if fresh.current.date != previous.current.date || force {
            await liveActivity.push(snapshot: fresh, unit: unit)
        }
        // Le serveur pousse les alertes par APNs dès qu'il est joignable :
        // on ne notifie localement que dans le cas contraire.
        if !SharedStore.shared.serverHandlesAlerts,
           let event = await NotificationManager.evaluateAndNotify(snapshot: fresh, unit: unit) {
            lastAlert = event
        }
    }

    /// Se recale sur la grille du site : le relevé tombe toutes les 10 min,
    /// on interroge 45 s après l'heure attendue pour ne jamais rater un cran.
    func startAutoRefresh() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let target = self.snapshot.current.date.addingTimeInterval(600 + 45)
                var delay = target.timeIntervalSinceNow
                if delay <= 5 { delay = 60 }          // relevé en retard : on repasse dans 1 min
                delay = min(delay, 11 * 60)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stopAutoRefresh() {
        timer?.cancel()
        timer = nil
    }
}
