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

    // MARK: Balises suivies

    /// Le serveur relève toutes les balises suivies, mais ne pousse l'activité en
    /// direct et les alertes que pour celle qui est sélectionnée.
    func syncBalises(_ catalog: BaliseCatalog) async throws {
        let payload = catalog.balises.map {
            ["id": $0.id, "name": $0.name, "altitude": $0.altitude as Any,
             "provider": $0.provider.rawValue]
        }
        try await post("api/balises", body: ["balises": payload, "selected": catalog.selectedID])
    }

    struct RemoteBalise: Decodable {
        let id: Int
        let name: String?
        let altitude: Int?
        let provider: String?
    }

    struct SensorHit: Decodable {
        let id: Int
        let name: String
        let lat: Double?
        let lon: Double?
        let altitude: Int?
    }

    struct SensorSearch: Decodable {
        struct IndexProgress: Decodable {
            let indexed: Int
            let scanned: Int
            let total: Int
        }
        let sensors: [SensorHit]
        let index: IndexProgress?
    }

    /// Recherche dans le catalogue d'une source (index tenu par le serveur).
    func searchSensors(provider: BaliseProvider, query: String) async throws -> SensorSearch {
        guard let baseURL else { throw ServerError.notConfigured }
        var components = URLComponents(url: baseURL.appendingPathComponent("api/sensors"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "provider", value: provider.rawValue),
                                  URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw ServerError.notConfigured }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(SensorSearch.self, from: data)
    }

    func fetchBalises() async throws -> [RemoteBalise] {
        guard let baseURL else { throw ServerError.notConfigured }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/balises"))
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, _) = try await URLSession.shared.data(for: request)
        struct Payload: Decodable { let balises: [RemoteBalise] }
        return try JSONDecoder().decode(Payload.self, from: data).balises
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
                "directionEnabled": settings.directionEnabled,
                "directionCenter": settings.directionCenter,
                "directionSpread": settings.directionSpread,
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
