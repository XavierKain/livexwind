import Foundation

/// Récupère le relevé d'une balise FFVL.
///
/// balisemeteo.com masque les valeurs (`!!! WARNING !!!`) tant que le client n'a pas
/// de session PHP : on amorce donc une requête sur l'accueil pour obtenir le cookie,
/// puis on lit la fiche balise. L'historique vient du serveur (Tailscale) ou, à
/// défaut, du flux JSON publié sur GitHub Pages — le site ne propose que des PNG.
struct BaliseClient: Sendable {
    let balise: Balise
    var baliseID: Int { balise.id }
    /// Identifiant chez la source — numérique sauf pour meteo.cat.
    private var sourceID: Int { Int(balise.code) ?? balise.id }

    init(balise: Balise) {
        self.balise = balise
    }

    /// Client pointant sur la balise actuellement sélectionnée.
    static var current: BaliseClient {
        BaliseClient(balise: SharedStore.shared.catalog.selected)
    }

    private var feedURL: URL { AppConfig.feedURL(key: balise.key) }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept-Language": "fr-FR,fr;q=0.9"
        ]
        return URLSession(configuration: config)
    }

    // MARK: - Page de la balise

    private func fetchPage() async throws -> String {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        _ = try? await session.data(from: URL(string: "https://www.balisemeteo.com/index.php")!)
        let (data, _) = try await session.data(from: AppConfig.pageURL(balise: sourceID))
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw WindError.decoding
        }
        return html
    }

    /// Relevé live : scraping FFVL, ou API JSON pour windmorbihan.
    func fetchCurrent() async throws -> WindReading {
        switch balise.provider {
        case .windMorbihan:
            return try await WindMorbihanClient.shared.latest(id: sourceID)
        case .windguru:
            return try await WindguruClient.shared.latest(id: sourceID)
        case .kwind:
            // kwind ne parle que WebSocket, avec un protocole applicatif propre.
            // Plutôt que d'embarquer ce client dans l'app, le widget et la montre,
            // on s'appuie sur le relevé que le serveur publie — il interroge la
            // station toutes les 25 s, la fraîcheur est la même.
            throw WindError.masked
        case .meteoCat:
            return try await MeteoCatClient.shared.latest(code: balise.code)
        case .ffvl:
            guard let reading = BaliseParser.parse(html: try await fetchPage()) else {
                throw WindError.masked
            }
            return reading
        }
    }

    /// Vérifie qu'une balise existe et renvoie sa fiche — utilisé à l'ajout.
    /// (Les capteurs windmorbihan sont choisis dans une liste, déjà décrite.)
    func fetchBalise() async throws -> Balise {
        switch balise.provider {
        case .windMorbihan:
            return balise
        case .windguru:
            return try await WindguruClient.shared.station(id: sourceID)
        case .meteoCat:
            return try await MeteoCatClient.shared.station(code: balise.code)
        case .kwind:
            // La fiche vient du catalogue public : pas besoin de WebSocket ici.
            guard let found = await StationCatalog.stations(for: .kwind)
                .first(where: { $0.code == balise.code }) else {
                throw WindError.unknownBalise
            }
            return found
        case .ffvl:
            let html = try await fetchPage()
            guard let found = BaliseParser.parseBalise(html: html, id: sourceID) else {
                throw WindError.unknownBalise
            }
            return found
        }
    }

    // MARK: - Historique

    /// Serveur (Tailscale) : le plus frais et le plus complet.
    func fetchServerFeed() async throws -> WindSnapshot {
        guard let base = ServerClient.shared.baseURL else { throw ServerError.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent("api/wind"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "balise", value: balise.code),
                                  URLQueryItem(name: "provider", value: balise.provider.rawValue)]
        guard let url = components?.url else { throw ServerError.notConfigured }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return try FeedPayload.decode(data).snapshot
    }

    /// Miroir public : écrit à chaque relevé, joignable sans VPN.
    func fetchPublicFeed() async throws -> WindSnapshot {
        var request = URLRequest(url: AppConfig.publicFeedURL(key: balise.key))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        return try FeedPayload.decode(data).snapshot
    }

    /// GitHub Pages : dernier filet, si le serveur est carrément hors ligne.
    func fetchFeed() async throws -> WindSnapshot {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return try FeedPayload.decode(data).snapshot
    }

    private func fetchHistorySource() async -> WindSnapshot? {
        if await ServerReach.shared.isWorthTrying() {
            do {
                let server = try await fetchServerFeed()
                await ServerReach.shared.note(reachable: true)
                if !server.history.isEmpty { return server }
            } catch {
                // Un flux illisible — balise que le serveur ne suit pas encore —
                // n'est pas une absence de serveur. Seule une panne de réseau
                // vaut la peine de le faire taire.
                await ServerReach.shared.note(reachable: !(error is URLError))
            }
        }
        if let mirror = try? await fetchPublicFeed(), !mirror.history.isEmpty { return mirror }
        return try? await fetchFeed()
    }

    // MARK: - Instantané complet

    /// Scraping direct pour la valeur la plus fraîche, flux pour l'historique,
    /// cache local en dernier recours.
    func loadSnapshot() async -> WindSnapshot {
        async let liveTask = try? await fetchCurrent()
        async let feedTask = await fetchHistorySource()
        let live = await liveTask
        let feed = await feedTask
        let cached = SharedStore.shared.loadSnapshot(key: balise.key)

        var history = feed?.history ?? cached?.history ?? []
        if let live {
            history.removeAll { abs($0.date.timeIntervalSince(live.date)) < 60 }
            history.append(live)
        }
        history.sort { $0.date < $1.date }
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        history = history.filter { $0.date >= cutoff }

        let current = live ?? feed?.current ?? cached?.current
        guard let current else {
            return cached ?? WindSnapshot.placeholder(balise: balise)
        }
        // Quand a-t-on regardé cette balise pour la dernière fois ?
        // Lecture directe réussie : maintenant. Sinon l'heure de relève du
        // serveur, qui vient de nous répondre — dater de maintenant un relevé
        // repris de son flux ferait passer pour muette une balise qu'il relit
        // très bien, seulement moins souvent que nous ne rafraîchissons l'écran.
        let observedAt = live != nil ? Date.now
            : (feed?.fetchedAt ?? cached?.fetchedAt ?? .now)

        let snapshot = WindSnapshot(
            baliseID: baliseID,
            baliseKey: balise.key,
            baliseName: balise.name,
            altitude: balise.altitude ?? feed?.altitude ?? cached?.altitude,
            latitude: balise.latitude ?? feed?.latitude ?? cached?.latitude,
            longitude: balise.longitude ?? feed?.longitude ?? cached?.longitude,
            current: current,
            history: history,
            fetchedAt: observedAt,
            periodSeconds: feed?.periodSeconds ?? cached?.periodSeconds ?? 600,
            silenceSeconds: feed?.silenceSeconds ?? cached?.silenceSeconds
        )
        SharedStore.shared.save(snapshot: snapshot)
        return snapshot
    }
}

/// Portée du serveur Tailscale, mémorisée d'un relevé à l'autre.
///
/// Il n'est joignable qu'à la maison. Ailleurs, son délai d'attente se payait à
/// chaque relevé : plusieurs secondes d'attente avant de retomber sur le miroir
/// public, qui porte pourtant exactement les mêmes données. On note donc son
/// absence et on l'ignore quelques minutes, plutôt que de la redécouvrir à
/// chaque fois.
private actor ServerReach {
    static let shared = ServerReach()
    /// Assez court pour qu'un retour à la maison soit vu sans rien faire.
    private static let pause: TimeInterval = 180
    private var mutedUntil: Date?

    func isWorthTrying() -> Bool {
        guard let mutedUntil else { return true }
        guard Date() >= mutedUntil else { return false }
        self.mutedUntil = nil
        return true
    }

    /// Joignable mais sans historique reste « joignable » : on ne le fait taire
    /// que lorsqu'il ne répond pas du tout.
    func note(reachable: Bool) {
        mutedUntil = reachable ? nil : Date().addingTimeInterval(Self.pause)
    }
}

enum WindError: Error, LocalizedError {
    case decoding
    case masked
    case unknownBalise

    var errorDescription: String? {
        switch self {
        case .decoding: return "Page illisible"
        case .masked: return "Relevé masqué par balisemeteo.com"
        case .unknownBalise: return "Aucune balise ne correspond à ce lien"
        }
    }
}

// MARK: - Parsing HTML

enum BaliseParser {
    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
    }

    private static func firstMatch(_ pattern: String, in text: String, group: Int = 1) -> String? {
        guard let re = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > group,
              let r = Range(m.range(at: group), in: text) else { return nil }
        return String(text[r])
    }

    private static func stripTags(_ fragment: String) -> String {
        fragment
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&eacute;", with: "é")
            .replacingOccurrences(of: "&agrave;", with: "à")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func labelledValue(_ label: String, in text: String) -> String? {
        let pattern = "<td class=\"label\">\\s*\(label)\\s*:\\s*</td>\\s*<td class=\"valeur\">(.*?)</td>"
        return firstMatch(pattern, in: text).map(stripTags)
    }

    private static func speed(_ value: String?) -> Double? {
        guard let value, let raw = firstMatch("(-?\\d+(?:[.,]\\d+)?)\\s*km/h", in: value) else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    private static func number(_ value: String?) -> Double? {
        guard let value, let raw = firstMatch("(-?\\d+(?:[.,]\\d+)?)", in: value) else { return nil }
        return Double(raw.replacingOccurrences(of: ",", with: "."))
    }

    private static func direction(_ value: String?) -> (Int?, String?) {
        guard let value else { return (nil, nil) }
        if let deg = firstMatch("(-?\\d+)\\s*°", in: value).flatMap(Int.init) {
            let label = firstMatch("([A-ZÀ-ÿ]{1,3})\\s*:", in: value)
            return ((deg % 360 + 360) % 360, label)
        }
        return (nil, nil)
    }

    /// Fiche d'identité de la balise (nom, altitude, position).
    static func parseBalise(html: String, id: Int) -> Balise? {
        // La page d'une balise inexistante ne contient ni fil d'ariane ni titre.
        var name = firstMatch("<p><b>([^<]+)</b></p>", in: html).map(stripTags)
        if name?.isEmpty ?? true {
            name = firstMatch("<h1>([^<]+)</h1>", in: html).map(stripTags)
        }
        guard let name, !name.isEmpty else { return nil }

        let altitude = firstMatch("Altitude\\s*:\\s*(\\d+)\\s*m", in: html).flatMap(Int.init)
        let lat = firstMatch("maps/preview\\?q=(-?\\d+\\.\\d+),(-?\\d+\\.\\d+)", in: html, group: 1)
            .flatMap(Double.init)
        let lon = firstMatch("maps/preview\\?q=(-?\\d+\\.\\d+),(-?\\d+\\.\\d+)", in: html, group: 2)
            .flatMap(Double.init)

        return Balise(id: id, name: name, altitude: altitude, latitude: lat, longitude: lon)
    }

    static func parse(html: String) -> WindReading? {
        guard let stamp = firstMatch("Relev(?:é|&eacute;) du ([^<]+)</div>", in: html),
              let date = parisDate(from: stamp) else { return nil }

        // Le bloc "Vent maxi" réutilise les mêmes libellés : on coupe la page en deux.
        let parts = html.components(separatedBy: "Vent maxi")
        let meanBlock = parts.first ?? html
        let gustBlock = parts.count > 1 ? parts[1] : html

        let (dir, label) = direction(labelledValue("Direction", in: meanBlock))
        let average = speed(labelledValue("Vitesse", in: meanBlock))
        let (gustDir, _) = direction(labelledValue("Direction", in: gustBlock))
        let gust = speed(labelledValue("Vitesse", in: gustBlock))

        guard average != nil || gust != nil else { return nil }  // page masquée

        return WindReading(
            date: date,
            directionDegrees: dir,
            directionLabel: label,
            averageKmh: average,
            gustKmh: gust,
            gustDirectionDegrees: gustDir,
            minKmh: speed(labelledValue("Vitesse minimum", in: html)),
            temperature: number(labelledValue("Température", in: html)),
            luminosity: number(labelledValue("Luminosité", in: html))
        )
    }

    /// "31/08/2026 - 13:02" exprimé en heure de Paris.
    static func parisDate(from stamp: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.timeZone = TimeZone(identifier: "Europe/Paris")
        formatter.dateFormat = "dd/MM/yyyy - HH:mm"
        return formatter.date(from: stamp.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Flux JSON

struct FeedPayload: Decodable {
    struct BaliseInfo: Decodable {
        let id: Int
        let name: String?
        let altitude: Int?
        let lat: Double?
        let lon: Double?
    }
    struct Sample: Decodable {
        let t: String?
        let dir: Int?
        let dirLabel: String?
        let avg: Double?
        let gust: Double?
        let gustDir: Int?
        let min: Double?
        let temp: Double?
        let lum: Double?
    }

    let balise: BaliseInfo
    let current: Sample
    let history: [Sample]
    let period: Double?
    /// Silence mesuré au-delà duquel la balise est muette — ce n'est pas sa
    /// cadence, voir `WindSnapshot.silenceSeconds`.
    let silence: Double?
    /// Heure à laquelle le serveur a obtenu ce relevé. C'est elle qui dit si la
    /// balise publiait, là où l'heure de lecture du flux ne dit que l'âge de
    /// notre copie — la montre et le widget lisent un miroir, pas la station.
    let generatedAt: String?
    /// Heure de la dernière tentative, quand elle n'a rien rapporté de neuf.
    /// Plus récente que `generatedAt`, elle dit « on a regardé, la balise n'a
    /// rien publié » — c'est ce qui la déclare muette plutôt que simplement
    /// pas relue.
    let checkedAt: String?

    static func decode(_ data: Data) throws -> FeedPayload {
        try JSONDecoder().decode(FeedPayload.self, from: data)
    }

    var snapshot: WindSnapshot {
        let readings = history.compactMap(Self.reading(from:)).sorted { $0.date < $1.date }
        let latest = Self.reading(from: current) ?? readings.last
        let identity = Balise(id: balise.id, name: balise.name ?? "Balise \(balise.id)",
                              altitude: balise.altitude, latitude: nil, longitude: nil)
        return WindSnapshot(
            baliseID: balise.id,
            baliseKey: identity.key,
            baliseName: identity.name,
            altitude: balise.altitude,
            latitude: balise.lat,
            longitude: balise.lon,
            current: latest ?? WindSnapshot.placeholder(balise: identity).current,
            history: readings,
            fetchedAt: Self.stamp(checkedAt) ?? Self.stamp(generatedAt) ?? .now,
            periodSeconds: period ?? 600,
            silenceSeconds: silence
        )
    }

    private static func stamp(_ iso: String?) -> Date? {
        iso.flatMap { ISO8601DateFormatter().date(from: $0) }
    }

    private static func reading(from sample: Sample) -> WindReading? {
        guard let t = sample.t, let date = ISO8601DateFormatter().date(from: t) else { return nil }
        return WindReading(
            date: date,
            directionDegrees: sample.dir,
            directionLabel: sample.dirLabel,
            averageKmh: sample.avg,
            gustKmh: sample.gust,
            gustDirectionDegrees: sample.gustDir,
            minKmh: sample.min,
            temperature: sample.temp,
            luminosity: sample.lum
        )
    }
}
