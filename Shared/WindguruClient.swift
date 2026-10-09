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

    /// Historique récent, en un seul appel.
    ///
    /// windguru refuse notre serveur depuis le 25/09/2026 — 403 sur chaque
    /// requête, pour un volume d'appels qui était le nôtre. Le téléphone, lui,
    /// a toujours le droit de lire : c'est donc lui qui va chercher la courbe,
    /// mais **une fois** quand on ouvre la balise, pas une fois par minute. Les
    /// relevés qui suivent viennent s'y ajouter tout seuls.
    ///
    /// Les séries arrivent en colonnes parallèles, indexées par `unixtime`.
    func history(id: Int, hours: Int = 48, step: Int = 10) async throws -> [WindReading] {
        let now = Date()
        let from = Self.stamp(now.addingTimeInterval(-Double(hours) * 3600))
        let to = Self.stamp(now)

        // `vars` limite les colonnes renvoyées — leur propre documentation
        // prévient que cette requête peut être lourde, autant ne pas demander
        // ce qu'on n'affiche pas. L'horodatage est toujours inclus d'office.
        let query = "q=station_data&id_station=\(id)&from=\(from)&to=\(to)"
            + "&avg_minutes=\(step)&vars=wind_avg,wind_max,wind_min,wind_direction,temperature"
        let (data, _) = try await URLSession.shared.data(for: request(query, timeout: 25))
        let series = try JSONDecoder().decode(SeriesPayload.self, from: data)
        return series.readings
    }

    /// « 2026-10-09T07:30:00.000Z », encodé pour la requête.
    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'.000Z'"
        return formatter.string(from: date)
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
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

    /// Séries de l'historique : des colonnes parallèles, pas des objets.
    /// Une station peut manquer un capteur, d'où les tableaux plus courts que
    /// les autres et les trous à l'intérieur.
    private struct SeriesPayload: Decodable {
        let unixtime: [Double]?
        let wind_avg: [Double?]?
        let wind_max: [Double?]?
        let wind_min: [Double?]?
        let wind_direction: [Double?]?
        let temperature: [Double?]?

        private func at(_ column: [Double?]?, _ index: Int) -> Double? {
            guard let column, index < column.count else { return nil }
            return column[index]
        }

        var readings: [WindReading] {
            (unixtime ?? []).enumerated().compactMap { index, stamp in
                let average = at(wind_avg, index)
                let gust = at(wind_max, index)
                guard average != nil || gust != nil else { return nil }
                let direction = at(wind_direction, index).map { ((Int($0) % 360) + 360) % 360 }
                return WindReading(
                    date: Date(timeIntervalSince1970: stamp),
                    directionDegrees: direction,
                    directionLabel: nil,
                    averageKmh: average.map { $0 * WindguruClient.knotToKmh },
                    gustKmh: gust.map { $0 * WindguruClient.knotToKmh },
                    gustDirectionDegrees: nil,
                    minKmh: at(wind_min, index).map { $0 * WindguruClient.knotToKmh },
                    temperature: at(temperature, index),
                    luminosity: nil
                )
            }
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
