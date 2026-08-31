import Foundation

/// Source de données d'une balise. Les deux sites ne publient pas du tout la
/// même chose : balisemeteo (FFVL) est une page HTML à scraper, windmorbihan
/// expose une API JSON en nœuds.
enum BaliseProvider: String, Codable, CaseIterable, Sendable {
    case ffvl
    case windMorbihan = "wm"

    var label: String { self == .ffvl ? "FFVL" : "Wind Morbihan" }
    var detail: String {
        self == .ffvl
        ? "balisemeteo.com — toute la France, relevé toutes les 10 min"
        : "windmorbihan.com — baie de Quiberon, relevé toutes les ~6 min"
    }
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
        }
    }

    var subtitle: String {
        var parts = [provider.label]
        if let altitude { parts.append("\(altitude) m") }
        return parts.joined(separator: " · ")
    }

    static let pyla = Balise(id: 64, name: "Pyla Pilat", altitude: 55,
                             latitude: 44.5761111, longitude: -1.2247222, provider: .ffvl)

    /// Accepte une URL balisemeteo.com collée depuis Safari, ou juste le numéro.
    /// (Wind Morbihan ne publie pas d'URL par balise : on y choisit dans une liste.)
    static func parseID(from input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let direct = Int(text), direct > 0 { return direct }

        let patterns = ["idBalise=(\\d+)", "balise[_-]?(\\d+)", "(\\d{1,5})"]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            if let match = re.firstMatch(in: text, range: range), match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: text), let value = Int(text[r]), value > 0 {
                return value
            }
        }
        return nil
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
