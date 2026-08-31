import Foundation

/// Dialogue avec le serveur LiveXWind (joint via Tailscale).
///
/// C'est lui qui garde les tokens push et qui pousse, à chaque nouveau relevé :
/// la mise à jour de l'activité en direct, son redémarrage à distance, et les
/// alertes de seuil. Sans lui l'app fonctionne quand même — elle lit la balise
/// directement — mais les mises à jour hors app dépendent alors d'iOS.
struct ServerClient: Sendable {
    static let shared = ServerClient()

    var baseURL: URL? {
        let raw = SharedStore.shared.serverURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        guard let baseURL else { throw ServerError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ServerError.badStatus
        }
    }

    // MARK: Tokens

    /// `kind` = "update" (activité en cours) ou "start" (push-to-start, iOS 17.2+).
    func registerActivityToken(_ token: String, kind: String, unit: WindUnit) async throws {
        try await post("api/live-activity/register",
                       body: ["token": token, "kind": kind, "unit": unit.rawValue])
    }

    func registerDeviceToken(_ token: String) async throws {
        try await post("api/device/register", body: ["token": token])
    }

    func stopActivity() async throws {
        try await post("api/live-activity/stop", body: [:])
    }

    // MARK: Seuils

    func pushAlertSettings(_ settings: AlertSettings, unit: WindUnit) async throws {
        try await post("api/alerts", body: [
            "unit": unit.rawValue,
            "alerts": [
                "enabled": settings.enabled,
                "upperEnabled": settings.upperEnabled,
                "upperKmh": settings.upperKmh,
                "lowerEnabled": settings.lowerEnabled,
                "lowerKmh": settings.lowerKmh,
                "useGusts": settings.useGusts,
                "startHour": settings.startHour,
                "endHour": settings.endHour,
                "cooldownMinutes": settings.cooldownMinutes
            ]
        ])
    }

    // MARK: Santé

    struct Health: Decodable {
        let ok: Bool
        let apns_configured: Bool
        let last_reading: String?
        let tokens: [String: Int]?
    }

    func health() async throws -> Health {
        guard let baseURL else { throw ServerError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/health"))
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Health.self, from: data)
    }
}

enum ServerError: Error, LocalizedError {
    case notConfigured
    case badStatus

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Adresse du serveur vide"
        case .badStatus: return "Le serveur a refusé la requête"
        }
    }
}
