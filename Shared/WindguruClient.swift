import Foundation

/// Source windguru.cz — des milliers de stations, toutes sur le même modèle.
///
/// Deux appels publics suffisent à l'app : la fiche de la station et son relevé
/// courant. L'historique passe par notre serveur, qui le récupère une fois puis
/// l'accumule. Les vitesses de windguru sont en nœuds.
struct WindguruClient: Sendable {
    static let shared = WindguruClient()

    private static let base = "https://www.windguru.cz/int/iapi.php"
    private static let knotToKmh = 1.852

    private func request(_ query: String, timeout: TimeInterval = 12) -> URLRequest {
        var request = URLRequest(url: URL(string: "\(Self.base)?\(query)")!)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("https://www.windguru.cz/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Fiche de la station — sert aussi à vérifier qu'un identifiant existe.
    func station(id: Int) async throws -> Balise {
        let (data, _) = try await URLSession.shared
            .data(for: request("q=station&id_station=\(id)&weather=false"))
        guard let info = try? JSONDecoder().decode(StationPayload.self, from: data),
              let stationID = info.id_station else {
            throw WindError.unknownBalise
        }
        return Balise(id: stationID, name: info.label, altitude: info.alt,
                      latitude: info.lat, longitude: info.lon,
                      provider: .windguru, code: String(stationID))
    }

    func latest(id: Int) async throws -> WindReading {
        let (data, _) = try await URLSession.shared
            .data(for: request("q=station_data_current&id_station=\(id)"))
        guard let row = try? JSONDecoder().decode(CurrentPayload.self, from: data),
              let reading = row.reading else {
            throw WindError.masked
        }
        return reading
    }

    // MARK: Décodage

    private struct StationPayload: Decodable {
        let id_station: Int?
        let name: String?
        let spotname: String?
        let lat: Double?
        let lon: Double?
        let alt: Int?

        /// « Tarifa — Campo de Futbol » plutôt que l'un ou l'autre.
        var label: String {
            let spot = (spotname ?? "").trimmingCharacters(in: .whitespaces)
            let station = (name ?? "").trimmingCharacters(in: .whitespaces)
            if !spot.isEmpty, !station.isEmpty,
               !station.lowercased().contains(spot.lowercased()) {
                return "\(spot) — \(station)"
            }
            return station.isEmpty ? (spot.isEmpty ? "Station \(id_station ?? 0)" : spot) : station
        }
    }

    private struct CurrentPayload: Decodable {
        let wind_avg: Double?
        let wind_max: Double?
        let wind_min: Double?
        let wind_direction: Double?
        let temperature: Double?
        let unixtime: Double?

        var reading: WindReading? {
            guard wind_avg != nil || wind_max != nil else { return nil }
            let direction = wind_direction.map { ((Int($0) % 360) + 360) % 360 }
            return WindReading(
                date: Date(timeIntervalSince1970: unixtime ?? Date().timeIntervalSince1970),
                directionDegrees: direction,
                directionLabel: nil,
                averageKmh: wind_avg.map { $0 * WindguruClient.knotToKmh },
                gustKmh: wind_max.map { $0 * WindguruClient.knotToKmh },
                gustDirectionDegrees: nil,
                minKmh: wind_min.map { $0 * WindguruClient.knotToKmh },
                temperature: temperature,
                luminosity: nil
            )
        }
    }
}
