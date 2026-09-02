import Foundation

/// Source meteo.cat — réseau XEMA de Catalogne, qui couvre Àger (station
/// « Montsec d'Ares », code WQ).
///
/// La page d'une station est rendue côté serveur : on lit le tableau
/// semi-horaire, dont les colonnes VVM (vent moyen), DVM (direction) et VVX
/// (rafale) sont déjà en km/h, avec des heures en TU — donc en UTC.
struct MeteoCatClient: Sendable {
    static let shared = MeteoCatClient()

    private static let base = "https://www.meteo.cat/observacions/xema/dades?codi="

    private func page(code: String) async throws -> String {
        var request = URLRequest(url: URL(string: Self.base + code)!)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("ca,fr;q=0.8", forHTTPHeaderField: "Accept-Language")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else { throw WindError.decoding }
        return html
    }

    func station(code: String) async throws -> Balise {
        let html = try await page(code: code)
        guard var name = Self.match("<title>([^<]+)</title>", in: html) else {
            throw WindError.unknownBalise
        }
        // Décoder d'abord : le titre contient « estaci&oacute; autom&agrave;tica »,
        // et retirer le préfixe avant décodage ne trouvait rien à retirer.
        name = name
            .replacingOccurrences(of: "&oacute;", with: "ó")
            .replacingOccurrences(of: "&agrave;", with: "à")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "Dades de l'estació automàtica", with: "")
        if let bar = name.range(of: "|") { name = String(name[..<bar.lowerBound]) }
        // Le titre finit par « (1.571 m) » : l'altitude s'y lit avant d'être ôtée.
        let altitude = Self.match("\\((\\d[\\d. ]*)\\s*m\\)", in: name)
            .map { $0.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: " ", with: "") }
            .flatMap(Int.init)
        name = name.replacingOccurrences(of: "\\s*\\(.*?\\)\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !name.contains("Meteocat") else { throw WindError.unknownBalise }
        return Balise(code: code, name: name, altitude: altitude, provider: .meteoCat)
    }

    func latest(code: String) async throws -> WindReading {
        guard let reading = Self.parse(html: try await page(code: code)).last else {
            throw WindError.masked
        }
        return reading
    }

    // MARK: Lecture du tableau

    private static func match(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    private static func strip(_ fragment: String) -> String {
        fragment
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(html: String) -> [WindReading] {
        // Le tableau des relevés est celui dont l'en-tête porte « Període ».
        let tables = html.components(separatedBy: "<table").dropFirst()
        guard let table = tables.first(where: { $0.contains("Període") }) else { return [] }

        let headers = matches("<th.*?</th>", in: table).map(strip)
        guard let iAvg = headers.firstIndex(where: { $0.replacingOccurrences(of: " ", with: "").hasPrefix("VVM") }),
              let iGust = headers.firstIndex(where: { $0.replacingOccurrences(of: " ", with: "").hasPrefix("VVX") })
        else { return [] }
        let iDir = headers.firstIndex { $0.replacingOccurrences(of: " ", with: "").hasPrefix("DVM") }
        let iTemp = headers.firstIndex { $0.replacingOccurrences(of: " ", with: "").hasPrefix("TM") }

        guard let day = pageDay(html) else { return [] }

        var readings: [WindReading] = []
        for row in matches("<tr.*?</tr>", in: table) {
            let cells = matches("<t[dh].*?</t[dh]>", in: row).map(strip)
            guard let first = cells.first, first.range(of: "^\\d{2}:\\d{2}", options: .regularExpression) != nil,
                  let end = match("-\\s*(\\d{2}):(\\d{2})", in: first) else { continue }

            let parts = first.components(separatedBy: "-")
            guard parts.count > 1 else { continue }
            let clock = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
            guard clock.count == 2, let hour = Int(clock[0]), let minute = Int(clock[1]) else { continue }
            _ = end

            func value(_ index: Int?) -> Double? {
                guard let index, index < cells.count else { return nil }
                return Double(cells[index].replacingOccurrences(of: ",", with: "."))
            }

            let avg = value(iAvg), gust = value(iGust)
            guard avg != nil || gust != nil else { continue }

            // Le relevé est daté de la fin de sa période ; 00:00 clôt la veille.
            var date = day.addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
            if hour == 0 && minute == 0 { date.addTimeInterval(24 * 3600) }

            let direction = value(iDir).map { ((Int($0) % 360) + 360) % 360 }
            readings.append(WindReading(date: date,
                                        directionDegrees: direction,
                                        directionLabel: nil,
                                        averageKmh: avg,
                                        gustKmh: gust,
                                        gustDirectionDegrees: nil,
                                        minKmh: nil,
                                        temperature: value(iTemp),
                                        luminosity: nil))
        }
        return readings
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// Jour affiché par la page, à minuit UTC : les heures du tableau sont en TU.
    private static func pageDay(_ html: String) -> Date? {
        guard let stamp = match("\\b(\\d{2}\\.\\d{2}\\.\\d{4})\\b", in: html) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: stamp)
    }
}
