import Foundation

/// Lecture du flux depuis l'Apple Watch.
///
/// La montre n'est pas sur Tailscale et ne sait pas scraper : elle lit le miroir
/// HTTPS public, écrit par le serveur à chaque relevé. Elle commence par demander
/// quelle balise l'iPhone affiche, pour rester d'accord avec lui sans appairage.
enum WatchFeed {
    struct Pointer: Decodable {
        let key: String
        let id: Int
        let name: String?
        let provider: String?
        let unit: String?

        var balise: Balise {
            Balise(id: id, name: name ?? "Balise \(id)",
                   provider: BaliseProvider(rawValue: provider ?? "ffvl") ?? .ffvl)
        }

        var windUnit: WindUnit { WindUnit(rawValue: unit ?? "") ?? .kmh }
    }

    /// Ce que la montre affiche : le relevé et l'unité choisie sur l'iPhone.
    struct Reading {
        var snapshot: WindSnapshot
        var unit: WindUnit
    }

    /// Une ligne de la liste des spots, telle que publiée par le serveur.
    struct Spot: Decodable {
        struct Current: Decodable {
            let avg: Double?
            let gust: Double?
            let dir: Int?
        }
        let key: String
        let id: Int
        let name: String
        let current: Current?
    }

    private struct Overview: Decodable { let spots: [Spot] }

    /// Tous les spots suivis, en une seule requête.
    static func spots() async -> [Spot] {
        guard let data = try? await get(AppConfig.publicMirror.appendingPathComponent("overview.json")),
              let overview = try? JSONDecoder().decode(Overview.self, from: data) else { return [] }
        return overview.spots
    }

    private static func get(_ url: URL, timeout: TimeInterval = 12) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func pointer() async -> Pointer? {
        guard let data = try? await get(AppConfig.selectedPointerURL) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }

    /// Balise affichée sur l'iPhone, son relevé et son unité. Retombe sur le
    /// cache local quand la montre n'a pas de réseau.
    ///
    /// L'unité vient du serveur et non des réglages locaux : la complication
    /// tourne dans un autre processus que l'app Watch, elle ne verrait sinon
    /// jamais le choix fait sur le téléphone.
    static func load() async -> Reading {
        let pointer = await pointer()
        let balise = pointer?.balise ?? SharedStore.shared.catalog.selected
        let unit = pointer?.windUnit ?? SharedStore.shared.unit
        SharedStore.shared.unit = unit

        if let data = try? await get(AppConfig.publicFeedURL(key: balise.key)),
           let snapshot = try? FeedPayload.decode(data).snapshot {
            SharedStore.shared.save(snapshot: snapshot)
            return Reading(snapshot: snapshot, unit: unit)
        }
        let cached = SharedStore.shared.loadSnapshot(key: balise.key) ?? .placeholder(balise: balise)
        return Reading(snapshot: cached, unit: unit)
    }
}
