import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class LiveActivityManager: ObservableObject {
    @Published var isActive = false
    @Published var lastError: String?
    @Published var pushTokenRegistered = false
    @Published var pushToStartRegistered = false
    /// Balise pour laquelle l'activité en cours a été lancée.
    @Published private(set) var activityBaliseKey: String?

    private var tokenTask: Task<Void, Never>?
    private var startTokenTask: Task<Void, Never>?

    #if canImport(ActivityKit)
    static func state(from snapshot: WindSnapshot, unit: WindUnit,
                      secondaries: [WindSnapshot] = []) -> WindActivityAttributes.ContentState {
        let trend = snapshot.history.suffix(18).compactMap(\.averageKmh)
        let r = snapshot.current
        let extras = secondaries.prefix(2).map { other in
            WindActivityAttributes.SecondaryWind(
                name: other.baliseName,
                averageKmh: other.current.averageKmh ?? 0,
                gustKmh: other.current.gustKmh ?? 0,
                directionDegrees: other.current.directionDegrees ?? 0,
                isOffline: other.isOffline
            )
        }
        return .init(
            averageKmh: r.averageKmh ?? 0,
            gustKmh: r.gustKmh ?? 0,
            minKmh: r.minKmh ?? 0,
            directionDegrees: r.directionDegrees ?? 0,
            directionLabel: r.compass,
            temperature: r.temperature,
            readingEpoch: r.date.timeIntervalSince1970,
            trendKmh: trend.isEmpty ? [r.averageKmh ?? 0] : trend,
            unitRaw: unit.rawValue,
            secondaries: extras.isEmpty ? nil : Array(extras)
        )
    }

    func refreshActiveState() {
        isActive = !Activity<WindActivityAttributes>.activities.isEmpty
    }

    /// À appeler au lancement : le token push-to-start permet au serveur de
    /// relancer l'activité tout seul, sans que l'app soit ouverte (iOS 17.2+).
    func observePushToStartToken(unit: WindUnit) {
        guard startTokenTask == nil else { return }
        startTokenTask = Task { [weak self] in
            for await tokenData in Activity<WindActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.hexString
                try? await ServerClient.shared.registerActivityToken(hex, kind: "start", unit: unit)
                self?.pushToStartRegistered = true
            }
        }
    }

    func start(snapshot: WindSnapshot, unit: WindUnit,
               secondaries: [WindSnapshot] = []) async {
        lastError = nil
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            lastError = "Activités en direct désactivées — Réglages > LiveXWind"
            return
        }
        for activity in Activity<WindActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        do {
            let attributes = WindActivityAttributes(baliseName: snapshot.baliseName, baliseID: snapshot.baliseID)
            let content = ActivityContent(
                state: Self.state(from: snapshot, unit: unit, secondaries: secondaries),
                staleDate: staleDate(for: snapshot)
            )
            // pushType .token : le serveur prend le relais dès que l'app est fermée.
            let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
            isActive = true
            activityBaliseKey = snapshot.baliseKey
            observeUpdateToken(of: activity, unit: unit, baliseKey: snapshot.baliseKey,
                               secondaries: secondaries.prefix(2).map(\.baliseKey))
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func observeUpdateToken(of activity: Activity<WindActivityAttributes>,
                                    unit: WindUnit, baliseKey: String,
                                    secondaries: [String]) {
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.hexString
                do {
                    try await ServerClient.shared.registerActivityToken(
                        hex, kind: "update", unit: unit, balise: baliseKey,
                        secondaries: secondaries)
                    self?.pushTokenRegistered = true
                } catch {
                    self?.pushTokenRegistered = false
                    self?.lastError = "Serveur injoignable — l'activité ne se mettra à jour que quand l'app tourne"
                }
            }
        }
    }

    /// Mise à jour locale, utilisée quand l'app est au premier plan (le serveur
    /// fait la même chose par push le reste du temps).
    ///
    /// On n'écrit que si l'instantané concerne bien la balise de l'activité :
    /// sinon on afficherait le vent du spot consulté sous le nom de celui pour
    /// lequel l'activité a été lancée.
    func push(snapshot: WindSnapshot, unit: WindUnit,
              secondaries: [WindSnapshot] = []) async {
        guard !Activity<WindActivityAttributes>.activities.isEmpty else {
            isActive = false
            activityBaliseKey = nil
            return
        }
        isActive = true
        guard activityBaliseKey == nil || activityBaliseKey == snapshot.baliseKey else { return }

        let content = ActivityContent(
            state: Self.state(from: snapshot, unit: unit, secondaries: secondaries),
            staleDate: staleDate(for: snapshot)
        )
        for activity in Activity<WindActivityAttributes>.activities {
            await activity.update(content)
        }
    }

    /// Péremption alignée sur la cadence de la balise, comme côté serveur :
    /// 25 minutes fixes laissaient une valeur morte affichée pour une station
    /// qui publie à la minute.
    private func staleDate(for snapshot: WindSnapshot) -> Date {
        snapshot.current.date.addingTimeInterval(max(snapshot.periodSeconds * 2 + 60, 300))
    }

    func stop() async {
        tokenTask?.cancel()
        tokenTask = nil
        for activity in Activity<WindActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        isActive = false
        pushTokenRegistered = false
        activityBaliseKey = nil
        try? await ServerClient.shared.stopActivity()
    }
    #else
    func refreshActiveState() {}
    func observePushToStartToken(unit: WindUnit) {}
    func start(snapshot: WindSnapshot, unit: WindUnit,
               secondaries: [WindSnapshot] = []) async {}
    func push(snapshot: WindSnapshot, unit: WindUnit,
              secondaries: [WindSnapshot] = []) async {}
    func stop() async {}
    #endif
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
