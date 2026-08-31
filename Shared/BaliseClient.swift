import Foundation

/// Récupère le relevé d'une balise FFVL.
///
/// balisemeteo.com masque les valeurs (`!!! WARNING !!!`) tant que le client n'a pas
/// de session PHP : on amorce donc une requête sur l'accueil pour obtenir le cookie,
/// puis on lit la fiche balise. L'historique vient d'un flux JSON publié toutes les
/// 10 min par GitHub Actions (le site ne propose que des graphes PNG).
struct BaliseClient: Sendable {
    static let shared = BaliseClient()

    let baliseID: Int
    let feedURL: URL

    init(baliseID: Int = AppConfig.baliseID, feedURL: URL = AppConfig.feedURL) {
        self.baliseID = baliseID
        self.feedURL = feedURL
    }

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

    // MARK: - Relevé live (scraping direct, zéro latence)

    func fetchCurrent() async throws -> WindReading {
        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        _ = try? await session.data(from: URL(string: "https://www.balisemeteo.com/index.php")!)
        let pageURL = URL(string: "https://www.balisemeteo.com/balise.php?idBalise=\(baliseID)")!
        let (data, _) = try await session.data(from: pageURL)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw WindError.decoding
        }
        guard let reading = BaliseParser.parse(html: html) else { throw WindError.masked }
        return reading
    }

    // MARK: - Flux JSON (historique + secours)

    func fetchFeed() async throws -> WindSnapshot {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, _) = try await URLSession.shared.data(for: request)
        return try FeedPayload.decode(data).snapshot
    }

    /// Stratégie complète : scraping direct pour la valeur la plus fraîche,
    /// flux JSON pour l'historique, cache local en dernier recours.
    func loadSnapshot() async -> WindSnapshot {
        async let liveTask = try? await fetchCurrent()
        async let feedTask = try? await fetchFeed()
        let live = await liveTask
        let feed = await feedTask
        let cached = SharedStore.shared.loadSnapshot()

        var history = feed?.history ?? cached?.history ?? []
        if let live {
            history.removeAll { abs($0.date.timeIntervalSince(live.date)) < 60 }
            history.append(live)
        }
        history.sort { $0.date < $1.date }
        let cutoff = Date().addingTimeInterval(-48 * 3600)
        history = history.filter { $0.date >= cutoff }

        let current = live ?? feed?.current ?? cached?.current
        guard let current else { return cached ?? .placeholder }

        let snapshot = WindSnapshot(
            baliseID: baliseID,
            baliseName: feed?.baliseName ?? cached?.baliseName ?? "Balise \(baliseID)",
            altitude: feed?.altitude ?? cached?.altitude,
            current: current,
            history: history,
            fetchedAt: .now
        )
        SharedStore.shared.save(snapshot: snapshot)
        return snapshot
    }
}

enum WindError: Error, LocalizedError {
    case decoding
    case masked

    var errorDescription: String? {
        switch self {
        case .decoding: return "Page illisible"
        case .masked: return "Relevé masqué par balisemeteo.com"
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
        let noTags = fragment.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags
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

    static func parse(html: String) -> WindReading? {
        guard let stamp = firstMatch("Relev(?:é|&eacute;) du ([^<]+)</div>", in: html) else { return nil }
        guard let date = parisDate(from: stamp) else { return nil }

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
        let cleaned = stamp.trimmingCharacters(in: .whitespacesAndNewlines)
        return formatter.date(from: cleaned)
    }
}

// MARK: - Flux JSON publié par GitHub Actions

private struct FeedPayload: Decodable {
    struct Balise: Decodable { let id: Int; let name: String?; let altitude: Int? }
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

    let balise: Balise
    let current: Sample
    let history: [Sample]

    static func decode(_ data: Data) throws -> FeedPayload {
        try JSONDecoder().decode(FeedPayload.self, from: data)
    }

    var snapshot: WindSnapshot {
        let readings = history.compactMap(Self.reading(from:)).sorted { $0.date < $1.date }
        let current = Self.reading(from: current) ?? readings.last
        return WindSnapshot(
            baliseID: balise.id,
            baliseName: balise.name ?? "Balise \(balise.id)",
            altitude: balise.altitude,
            current: current ?? WindSnapshot.placeholder.current,
            history: readings,
            fetchedAt: .now
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
