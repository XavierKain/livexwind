import Foundation

/// Source de données d'une balise. Les deux sites ne publient pas du tout la
/// même chose : balisemeteo (FFVL) est une page HTML à scraper, windmorbihan
/// expose une API JSON en nœuds.
enum BaliseProvider: String, Codable, CaseIterable, Sendable {
    case ffvl
    case windMorbihan = "wm"
    case windguru = "wg"

    var label: String {
        switch self {
        case .ffvl: return "FFVL"
        case .windMorbihan: return "Morbihan"
        case .windguru: return "Windguru"
        }
    }

    var detail: String {
        switch self {
        case .ffvl:
            return "balisemeteo.com — toute la France, relevé toutes les 10 min"
        case .windMorbihan:
            return "windmorbihan.com — baie de Quiberon, relevé toutes les ~6 min"
        case .windguru:
            return "windguru.cz — des milliers de stations dans le monde, dont Tarifa"
        }
    }

    /// Vrai quand on peut ajouter une balise en collant un lien.
    var acceptsLink: Bool { self != .windMorbihan }
}

/// Une balise météo suivie par l'app.
struct Balise: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var altitude: Int?
    var latitude: Double?
    var longitude: Double?
    var provider: BaliseProvider

    init(id: Int, name: String, altitude: Int? = nil,
         latitude: Double? = nil, longitude: Double? = nil,
         provider: BaliseProvider = .ffvl) {
        self.id = id
        self.name = name
        self.altitude = altitude
        self.latitude = latitude
        self.longitude = longitude
        self.provider = provider
    }

    // Les balises enregistrées avant l'arrivée des sources multiples n'ont pas
    // de champ `provider` : elles viennent forcément de la FFVL.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        altitude = try c.decodeIfPresent(Int.self, forKey: .altitude)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        provider = try c.decodeIfPresent(BaliseProvider.self, forKey: .provider) ?? .ffvl
    }

    /// Identifiant stable pour les caches et les noms de fichiers de flux.
    var key: String { "\(provider.rawValue)-\(id)" }

    var pageURL: URL {
        switch provider {
        case .ffvl:
            return URL(string: "https://www.balisemeteo.com/balise.php?idBalise=\(id)")!
        case .windMorbihan:
            return URL(string: "https://www.windmorbihan.com")!
        case .windguru:
            return URL(string: "https://www.windguru.cz/station/\(id)")!
        }
    }

    var subtitle: String {
        var parts = [provider.label]
        if let altitude { parts.append("\(altitude) m") }
        return parts.joined(separator: " · ")
    }

    static let pyla = Balise(id: 64, name: "Pyla Pilat", altitude: 55,
                             latitude: 44.5761111, longitude: -1.2247222, provider: .ffvl)

    /// Reconnaît un lien collé depuis Safari et en déduit la source.
    ///
    /// - `balisemeteo.com/balise.php?idBalise=64` → FFVL 64
    /// - `windguru.cz/station/2667`               → Windguru 2667
    /// - un simple numéro                         → source proposée par défaut
    ///
    /// (Wind Morbihan n'a pas d'URL par capteur : on y choisit dans une liste.)
    static func parseLink(_ input: String, fallback: BaliseProvider = .ffvl) -> (provider: BaliseProvider, id: Int)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let id = firstGroup("windguru\\.cz/station/(\\d+)", in: text) {
            return (.windguru, id)
        }
        if let id = firstGroup("idBalise=(\\d+)", in: text) {
            return (.ffvl, id)
        }
        if let id = firstGroup("balisemeteo\\.com[^0-9]{0,20}(\\d+)", in: text) {
            return (.ffvl, id)
        }
        if let direct = Int(text), direct > 0 {
            return (fallback, direct)
        }
        if let id = firstGroup("(\\d{1,7})", in: text) {
            return (fallback, id)
        }
        return nil
    }

    private static func firstGroup(_ pattern: String, in text: String) -> Int? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text), let value = Int(text[r]), value > 0 else { return nil }
        return value
    }
}

/// Liste des balises suivies + celle qui est affichée. Stockée dans les réglages
/// de l'app ; le serveur en reçoit une copie pour savoir lesquelles relever.
struct BaliseCatalog: Codable, Equatable, Sendable {
    var balises: [Balise]
    var selectedID: Int

    static let `default` = BaliseCatalog(balises: [.pyla], selectedID: Balise.pyla.id)

    var selected: Balise {
        balises.first { $0.id == selectedID } ?? balises.first ?? .pyla
    }

    mutating func add(_ balise: Balise) {
        if let index = balises.firstIndex(where: { $0.key == balise.key }) {
            balises[index] = balise
        } else {
            balises.append(balise)
        }
        selectedID = balise.id
    }

    mutating func remove(id: Int) {
        guard balises.count > 1 else { return }   // on en garde toujours une
        balises.removeAll { $0.id == id }
        if selectedID == id { selectedID = balises.first?.id ?? Balise.pyla.id }
    }

    var selectedKey: String { selected.key }
}
