import Foundation

/// Source de données d'une balise. Les deux sites ne publient pas du tout la
/// même chose : balisemeteo (FFVL) est une page HTML à scraper, windmorbihan
/// expose une API JSON en nœuds.
enum BaliseProvider: String, Codable, CaseIterable, Sendable {
    case ffvl
    case windMorbihan = "wm"
    case windguru = "wg"
    case meteoCat = "mc"

    var label: String {
        switch self {
        case .ffvl: return "FFVL"
        case .windMorbihan: return "Morbihan"
        case .windguru: return "Windguru"
        case .meteoCat: return "Meteo.cat"
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
        case .meteoCat:
            return "meteo.cat — réseau XEMA de Catalogne, dont Àger, relevé toutes les 30 min"
        }
    }

    /// Vrai quand on peut ajouter une balise en collant un lien.
    var acceptsLink: Bool { self != .windMorbihan }
}

/// Une balise météo suivie par l'app.
struct Balise: Codable, Hashable, Identifiable, Sendable {
    /// Identifiant interne, numérique : c'est lui qui circule dans la sélection,
    /// les réglages et le lien avec l'Apple Watch.
    var id: Int
    /// Identifiant chez la source. Numérique pour la FFVL, windmorbihan et
    /// windguru ; alphabétique pour meteo.cat (« WQ » pour le Montsec d'Ares).
    var code: String
    var name: String
    var altitude: Int?
    var latitude: Double?
    var longitude: Double?
    var provider: BaliseProvider

    init(id: Int, name: String, altitude: Int? = nil,
         latitude: Double? = nil, longitude: Double? = nil,
         provider: BaliseProvider = .ffvl, code: String? = nil) {
        self.id = id
        self.code = code ?? String(id)
        self.name = name
        self.altitude = altitude
        self.latitude = latitude
        self.longitude = longitude
        self.provider = provider
    }

    /// Balise identifiée par un code texte : l'entier en est dérivé, de façon
    /// stable, pour rester utilisable là où un identifiant numérique est attendu.
    init(code: String, name: String, altitude: Int? = nil,
         latitude: Double? = nil, longitude: Double? = nil,
         provider: BaliseProvider) {
        self.init(id: Balise.handle(for: code), name: name, altitude: altitude,
                  latitude: latitude, longitude: longitude, provider: provider, code: code)
    }

    /// Un code alphanumérique lu en base 36 — court, stable et sans collision
    /// entre codes différents.
    static func handle(for code: String) -> Int {
        if let numeric = Int(code) { return numeric }
        return code.uppercased().unicodeScalars.reduce(0) { total, scalar in
            let digit: Int
            switch scalar {
            case "0"..."9": digit = Int(scalar.value - 48)
            case "A"..."Z": digit = Int(scalar.value - 55)
            default: digit = 0
            }
            return total * 36 + digit
        }
    }

    // Les balises enregistrées avant l'arrivée des sources multiples n'ont pas
    // de champ `provider` : elles viennent forcément de la FFVL.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        // Les balises enregistrées avant meteo.cat n'ont pas de code : chez ces
        // sources, l'identifiant numérique en tient lieu.
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? String(id)
        name = try c.decode(String.self, forKey: .name)
        altitude = try c.decodeIfPresent(Int.self, forKey: .altitude)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        provider = try c.decodeIfPresent(BaliseProvider.self, forKey: .provider) ?? .ffvl
    }

    /// Identifiant stable pour les caches et les noms de fichiers de flux.
    var key: String { "\(provider.rawValue)-\(code)" }

    var pageURL: URL {
        switch provider {
        case .ffvl:
            return URL(string: "https://www.balisemeteo.com/balise.php?idBalise=\(id)")!
        case .windMorbihan:
            return URL(string: "https://www.windmorbihan.com")!
        case .windguru:
            return URL(string: "https://www.windguru.cz/station/\(code)")!
        case .meteoCat:
            return URL(string: "https://www.meteo.cat/observacions/xema/dades?codi=\(code)")!
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
    static func parseLink(_ input: String, fallback: BaliseProvider = .ffvl) -> (provider: BaliseProvider, code: String)? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let code = firstText("meteo\\.cat[^\\s]*codi=([A-Za-z0-9]{1,5})", in: text) {
            return (.meteoCat, code.uppercased())
        }
        if let code = firstText("windguru\\.cz/station/(\\d+)", in: text) {
            return (.windguru, code)
        }
        if let code = firstText("idBalise=(\\d+)", in: text) {
            return (.ffvl, code)
        }
        if let code = firstText("balisemeteo\\.com[^0-9]{0,20}(\\d+)", in: text) {
            return (.ffvl, code)
        }
        if fallback == .meteoCat, text.count <= 5, text.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil {
            return (.meteoCat, text.uppercased())
        }
        if Int(text) != nil {
            return (fallback, text)
        }
        if let code = firstText("(\\d{1,7})", in: text) {
            return (fallback, code)
        }
        return nil
    }

    private static func firstText(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[r])
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
