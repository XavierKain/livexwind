import Foundation

/// Catalogue de stations téléchargé depuis le miroir public.
///
/// La recherche passait auparavant par l'API du serveur, joignable seulement par
/// Tailscale : dès que le téléphone quittait le réseau privé, chercher un spot
/// devenait impossible alors que tout le reste de l'app continuait de marcher.
/// Le serveur publie donc les catalogues en clair, et la recherche se fait ici.
enum StationCatalog {
    /// Un catalogue est téléchargé une fois par session ; nginx le laisse aussi
    /// en cache une journée côté HTTP.
    private static var cache: [BaliseProvider: [Balise]] = [:]
    private static let lock = NSLock()

    private struct Payload: Decodable {
        struct Entry: Decodable {
            let c: String        // code chez la source
            let n: String        // nom
            let a: Double?       // latitude
            let o: Double?       // longitude
            let e: Int?          // altitude
        }
        let stations: [Entry]
    }

    static func stations(for provider: BaliseProvider) async -> [Balise] {
        lock.lock()
        let cached = cache[provider]
        lock.unlock()
        if let cached { return cached }

        let url = AppConfig.publicMirror.appendingPathComponent("stations-\(provider.rawValue).json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.cachePolicy = .returnCacheDataElseLoad

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }

        let balises = payload.stations.map {
            Balise(code: $0.c, name: $0.n, altitude: $0.e,
                   latitude: $0.a, longitude: $0.o, provider: provider)
        }
        lock.lock()
        cache[provider] = balises
        lock.unlock()
        return balises
    }

    /// Recherche par nom ou par code, insensible à la casse et aux accents.
    static func search(_ query: String, provider: BaliseProvider, limit: Int = 40) async -> [Balise] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        let all = await stations(for: provider)
        let hits = all.filter { fold($0.name).contains(needle) || fold($0.code) == needle }
        return Array(hits.sorted {
            let a = fold($0.name).hasPrefix(needle), b = fold($1.name).hasPrefix(needle)
            return a == b ? $0.name < $1.name : a
        }.prefix(limit))
    }

    /// Stations les plus proches d'un point, triées par distance.
    static func nearby(latitude: Double, longitude: Double, provider: BaliseProvider,
                       radiusKm: Double = 60, limit: Int = 30) async -> [(balise: Balise, km: Double)] {
        let all = await stations(for: provider)
        let hits = all.compactMap { balise -> (Balise, Double)? in
            guard let lat = balise.latitude, let lon = balise.longitude else { return nil }
            let km = distance(latitude, longitude, lat, lon)
            return km <= radiusKm ? (balise, km) : nil
        }
        return Array(hits.sorted { $0.1 < $1.1 }.prefix(limit))
    }

    // MARK: Outils

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func distance(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let radius = 6371.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * radius * asin(min(1, sqrt(a)))
    }
}
