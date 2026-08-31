import Foundation

/// Source windmorbihan.com : une vraie API JSON, en nœuds.
///
/// Deux fichiers suffisent pour l'app : la liste des capteurs (46 Ko, mise en
/// cache) et le dernier relevé de tous les capteurs (15 Ko). L'historique du
/// site fait 6 Mo, on ne le télécharge jamais depuis le téléphone — c'est le
/// serveur qui le récupère une fois et qui nous sert la courbe.
struct WindMorbihanClient: Sendable {
    static let shared = WindMorbihanClient()

    private static let sensorsURL = URL(string: "https://backend.windmorbihan.com/capteurs/list.json")!
    private static let latestURL = URL(string: "https://private2.windmorbihan.com/mesures/getlastalljson.json")!
    private static let knotToKmh = 1.852

    private func request(_ url: URL, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://www.windmorbihan.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    // MARK: Capteurs

    func sensors() async throws -> [Balise] {
        let (data, _) = try await URLSession.shared.data(for: request(Self.sensorsURL, timeout: 20))
        let payload = try JSONDecoder().decode(SensorsPayload.self, from: data)
        return payload.sensors.WindSensor
            .compactMap { key, sensor -> Balise? in
                guard let id = Int(key) else { return nil }
                return Balise(id: id, name: sensor.label ?? "Capteur \(id)",
                              altitude: nil, latitude: sensor.lat, longitude: sensor.lng,
                              provider: .windMorbihan)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Relevé

    func latest(id: Int) async throws -> WindReading {
        let (data, _) = try await URLSession.shared.data(for: request(Self.latestURL))
        let rows = try JSONDecoder().decode([LatestRow].self, from: data)
        guard let row = rows.first(where: { $0.nid == id }), let reading = row.reading else {
            throw WindError.masked
        }
        return reading
    }

    // MARK: Décodage

    private struct SensorsPayload: Decodable {
        struct Group: Decodable { let WindSensor: [String: Sensor] }
        struct Sensor: Decodable {
            let label: String?
            let lat: Double?
            let lng: Double?
        }
        let sensors: Group
    }

    private struct LatestRow: Decodable {
        let nid: Int
        let created: [String: String]?
        let wind_dir_true: Double?
        let wind_pow_knot: Double?
        let wind_pow_knot_max: Double?

        /// `created` est un dictionnaire {epoch: "libellé"} — l'epoch fait foi.
        var date: Date {
            guard let epoch = created?.keys.compactMap(Double.init).first else { return .now }
            return Date(timeIntervalSince1970: epoch)
        }

        var reading: WindReading? {
            guard wind_pow_knot != nil || wind_pow_knot_max != nil else { return nil }
            let direction = wind_dir_true.map { ((Int($0) % 360) + 360) % 360 }
            return WindReading(
                date: date,
                directionDegrees: direction,
                directionLabel: nil,   // recalculé par WindReading.compass
                averageKmh: wind_pow_knot.map { $0 * WindMorbihanClient.knotToKmh },
                gustKmh: wind_pow_knot_max.map { $0 * WindMorbihanClient.knotToKmh },
                gustDirectionDegrees: nil,
                minKmh: nil,
                temperature: nil,
                luminosity: nil
            )
        }
    }
}
