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
        request.timeoutInterval = 8
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
        if let server = try? await fetchServerFeed(), !server.history.isEmpty { return server }
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

        let snapshot = WindSnapshot(
            baliseID: baliseID,
            baliseKey: balise.key,
            baliseName: balise.name,
            altitude: balise.altitude ?? feed?.altitude ?? cached?.altitude,
            current: current,
            history: history,
            fetchedAt: .now,
            periodSeconds: feed?.periodSeconds ?? cached?.periodSeconds ?? 600
        )
        SharedStore.shared.save(snapshot: snapshot)
        return snapshot
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
    struct BaliseInfo: Decodable { let id: Int; let name: String?; let altitude: Int? }
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
            current: latest ?? WindSnapshot.placeholder(balise: identity).current,
            history: readings,
            fetchedAt: .now,
            periodSeconds: period ?? 600
        )
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
