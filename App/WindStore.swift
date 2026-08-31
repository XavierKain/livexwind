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

    /// Seuils de la balise affichée — chaque spot a les siens.
    @Published var alerts: AlertSettings {
        didSet {
            guard alerts != oldValue else { return }
            SharedStore.shared.setAlertSettings(alerts, for: catalog.selectedKey)
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
    @Published private(set) var catalog: BaliseCatalog
    /// Instantané par balise suivie, pour la vue d'ensemble.
    @Published private(set) var overview: [String: WindSnapshot] = [:]
    @Published var notificationsAuthorized = false
    @Published var lastAlert: AlertEvent?

    let liveActivity = LiveActivityManager()
    private var timer: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init() {
        let stored = SharedStore.shared.catalog
        catalog = stored
        let cached = SharedStore.shared.loadSnapshot(key: stored.selectedKey)
        snapshot = cached ?? .placeholder(balise: stored.selected)
        unit = SharedStore.shared.unit
        alerts = SharedStore.shared.alertSettings(for: stored.selectedKey)
        serverURL = SharedStore.shared.serverURL

        // LiveActivityManager est un ObservableObject imbriqué : sans ce relais,
        // la vue ne se redessine pas quand son état change (bouton figé).
        liveActivity.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Le serveur garde les seuils de son côté pour pouvoir notifier app fermée.
    /// On lui pousse ceux de toutes les balises : il surveille chaque spot,
    /// même celui qui n'est pas affiché.
    func syncAlertsWithServer() async {
        do {
            for balise in catalog.balises {
                try await ServerClient.shared.pushAlertSettings(
                    SharedStore.shared.alertSettings(for: balise.key), for: balise, unit: unit)
            }
            SharedStore.shared.serverHandlesAlerts = true
            serverReachable = true
        } catch {
            SharedStore.shared.serverHandlesAlerts = false
            serverReachable = false
        }
    }

    // MARK: Balises

    var balise: Balise { catalog.selected }

    /// Résumé court des seuils d'une balise, pour la vue d'ensemble.
    func alertBadge(for balise: Balise) -> Bool {
        SharedStore.shared.alertSettings(for: balise.key).enabled
    }

    /// Recharge toutes les balises suivies en parallèle. Le serveur ayant déjà
    /// leurs relevés, c'est presque instantané sur Tailscale.
    func refreshOverview(force: Bool = false) async {
        let balises = catalog.balises
        var fresh: [String: WindSnapshot] = [:]

        await withTaskGroup(of: (String, WindSnapshot).self) { group in
            for balise in balises {
                if !force, let cached = overview[balise.key],
                   Date().timeIntervalSince(cached.fetchedAt) < 120 {
                    fresh[balise.key] = cached
                    continue
                }
                group.addTask {
                    (balise.key, await BaliseClient(balise: balise).loadSnapshot())
                }
            }
            for await (key, snapshot) in group {
                fresh[key] = snapshot
            }
        }
        overview = fresh
        if let mine = fresh[catalog.selectedKey] { snapshot = mine }

        // Hors Tailscale, le serveur ne peut pas notifier : on évalue nous-mêmes
        // les seuils de chaque spot avec ce qu'on vient de charger.
        if !SharedStore.shared.serverHandlesAlerts {
            for snapshot in fresh.values {
                await NotificationManager.evaluateAndNotify(snapshot: snapshot, unit: unit)
            }
        }
    }

    func select(baliseID: Int) async {
        guard catalog.selectedID != baliseID else { return }
        catalog.selectedID = baliseID
        alerts = SharedStore.shared.alertSettings(for: catalog.selectedKey)
        persistCatalog()
        // On repart de la courbe en cache le temps du chargement : pas d'écran vide.
        snapshot = SharedStore.shared.loadSnapshot(key: catalog.selectedKey)
            ?? .placeholder(balise: catalog.selected)
        await refresh(force: true)
    }

    /// Ajoute une balise depuis un lien collé (ou un numéro). La source est
    /// déduite du lien ; `fallback` tranche quand on n'a qu'un numéro.
    @discardableResult
    func addBalise(from input: String, fallback: BaliseProvider = .ffvl) async throws -> Balise {
        guard let parsed = Balise.parseLink(input, fallback: fallback) else {
            throw WindError.unknownBalise
        }
        let candidate = Balise(id: parsed.id, name: "Balise \(parsed.id)", provider: parsed.provider)
        return await install(try await BaliseClient(balise: candidate).fetchBalise())
    }

    /// Ajoute un capteur choisi dans la liste d'une source qui en publie une.
    @discardableResult
    func addBalise(_ balise: Balise) async -> Balise {
        await install(balise)
    }

    private func install(_ balise: Balise) async -> Balise {
        catalog.add(balise)
        alerts = SharedStore.shared.alertSettings(for: balise.key)
        persistCatalog()
        snapshot = SharedStore.shared.loadSnapshot(key: balise.key) ?? .placeholder(balise: balise)
        await refresh(force: true)
        return balise
    }

    func removeBalise(id: Int) async {
        let wasSelected = catalog.selectedID == id
        catalog.remove(id: id)
        persistCatalog()
        if wasSelected {
            alerts = SharedStore.shared.alertSettings(for: catalog.selectedKey)
            snapshot = SharedStore.shared.loadSnapshot(key: catalog.selectedKey)
                ?? .placeholder(balise: catalog.selected)
            await refresh(force: true)
        }
    }

    private func persistCatalog() {
        SharedStore.shared.catalog = catalog
        Task { try? await ServerClient.shared.syncBalises(catalog) }
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
            try? await ServerClient.shared.syncBalises(catalog)
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

        let fresh = await BaliseClient(balise: catalog.selected).loadSnapshot()
        let previous = snapshot
        snapshot = fresh
        overview[catalog.selectedKey] = fresh
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

    /// Se recale sur la cadence propre à la balise — une station windguru publie
    /// à la minute, une balise FFVL toutes les 10 min.
    func startAutoRefresh() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let period = self.snapshot.periodSeconds
                let target = self.snapshot.current.date.addingTimeInterval(period + 8)
                var delay = target.timeIntervalSinceNow
                if delay <= 3 { delay = min(20, period) }   // relevé en retard : on repasse vite
                delay = min(delay, period + 60)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    func stopAutoRefresh() {
        timer?.cancel()
        timer = nil
    }
}
