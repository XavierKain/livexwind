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

    private var tokenTask: Task<Void, Never>?
    private var startTokenTask: Task<Void, Never>?

    #if canImport(ActivityKit)
    static func state(from snapshot: WindSnapshot, unit: WindUnit) -> WindActivityAttributes.ContentState {
        let trend = snapshot.history.suffix(18).compactMap(\.averageKmh)
        let r = snapshot.current
        return .init(
            averageKmh: r.averageKmh ?? 0,
            gustKmh: r.gustKmh ?? 0,
            minKmh: r.minKmh ?? 0,
            directionDegrees: r.directionDegrees ?? 0,
            directionLabel: r.compass,
            temperature: r.temperature,
            readingEpoch: r.date.timeIntervalSince1970,
            trendKmh: trend.isEmpty ? [r.averageKmh ?? 0] : trend,
            unitRaw: unit.rawValue
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

    func start(snapshot: WindSnapshot, unit: WindUnit) async {
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
                state: Self.state(from: snapshot, unit: unit),
                staleDate: snapshot.current.date.addingTimeInterval(25 * 60)
            )
            // pushType .token : le serveur prend le relais dès que l'app est fermée.
            let activity = try Activity.request(attributes: attributes, content: content, pushType: .token)
            isActive = true
            observeUpdateToken(of: activity, unit: unit)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func observeUpdateToken(of activity: Activity<WindActivityAttributes>, unit: WindUnit) {
        tokenTask?.cancel()
        tokenTask = Task { [weak self] in
            for await tokenData in activity.pushTokenUpdates {
                let hex = tokenData.hexString
                do {
                    try await ServerClient.shared.registerActivityToken(hex, kind: "update", unit: unit)
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
    func push(snapshot: WindSnapshot, unit: WindUnit) async {
        guard !Activity<WindActivityAttributes>.activities.isEmpty else {
            isActive = false
            return
        }
        let content = ActivityContent(
            state: Self.state(from: snapshot, unit: unit),
            staleDate: snapshot.current.date.addingTimeInterval(25 * 60)
        )
        for activity in Activity<WindActivityAttributes>.activities {
            await activity.update(content)
        }
        isActive = true
    }

    func stop() async {
        tokenTask?.cancel()
        tokenTask = nil
        for activity in Activity<WindActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        isActive = false
        pushTokenRegistered = false
        try? await ServerClient.shared.stopActivity()
    }
    #else
    func refreshActiveState() {}
    func observePushToStartToken(unit: WindUnit) {}
    func start(snapshot: WindSnapshot, unit: WindUnit) async {}
    func push(snapshot: WindSnapshot, unit: WindUnit) async {}
    func stop() async {}
    #endif
}

extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
