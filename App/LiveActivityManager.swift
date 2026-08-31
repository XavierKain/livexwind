import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class LiveActivityManager: ObservableObject {
    @Published var isActive = false
    @Published var lastError: String?

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
            _ = try Activity.request(attributes: attributes, content: content, pushType: nil)
            isActive = true
        } catch {
            lastError = error.localizedDescription
        }
    }

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
        for activity in Activity<WindActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        isActive = false
    }
    #else
    func refreshActiveState() {}
    func start(snapshot: WindSnapshot, unit: WindUnit) async {}
    func push(snapshot: WindSnapshot, unit: WindUnit) async {}
    func stop() async {}
    #endif
}
