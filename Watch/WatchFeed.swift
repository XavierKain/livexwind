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

        var balise: Balise {
            Balise(id: id, name: name ?? "Balise \(id)",
                   provider: BaliseProvider(rawValue: provider ?? "ffvl") ?? .ffvl)
        }
    }

    private static func get(_ url: URL, timeout: TimeInterval = 12) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    static func selectedBalise() async -> Balise {
        if let data = try? await get(AppConfig.selectedPointerURL),
           let pointer = try? JSONDecoder().decode(Pointer.self, from: data) {
            return pointer.balise
        }
        return SharedStore.shared.catalog.selected
    }

    /// Balise affichée sur l'iPhone + son relevé. Retombe sur le cache local
    /// quand la montre n'a pas de réseau.
    static func load() async -> WindSnapshot {
        let balise = await selectedBalise()
        if let data = try? await get(AppConfig.publicFeedURL(key: balise.key)),
           let snapshot = try? FeedPayload.decode(data).snapshot {
            SharedStore.shared.save(snapshot: snapshot)
            return snapshot
        }
        return SharedStore.shared.loadSnapshot(key: balise.key) ?? .placeholder(balise: balise)
    }
}
