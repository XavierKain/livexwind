import Foundation

/// Une balise météo FFVL suivie par l'app.
struct Balise: Codable, Hashable, Identifiable, Sendable {
    var id: Int
    var name: String
    var altitude: Int?
    var latitude: Double?
    var longitude: Double?

    var pageURL: URL {
        URL(string: "https://www.balisemeteo.com/balise.php?idBalise=\(id)")!
    }

    var subtitle: String {
        var parts = ["#\(id)"]
        if let altitude { parts.append("\(altitude) m") }
        return parts.joined(separator: " · ")
    }

    static let pyla = Balise(id: 64, name: "Pyla Pilat", altitude: 55,
                             latitude: 44.5761111, longitude: -1.2247222)

    /// Accepte une URL balisemeteo.com collée depuis Safari, ou juste le numéro.
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
        if let index = balises.firstIndex(where: { $0.id == balise.id }) {
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
}
