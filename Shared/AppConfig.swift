import Foundation

enum AppConfig {
    /// Balise FFVL suivie par défaut — Pyla / Dune du Pilat.
    static let baliseID = 64
    static let widgetKind = "LiveXWindWidget"

    /// Historique publié par le serveur sur GitHub Pages, une balise par fichier.
    static func feedURL(balise: Int) -> URL {
        URL(string: "https://xavierkain.github.io/livexwind/balise-\(balise).json")!
    }

    /// Serveur de push (Tailscale) : c'est lui qui pousse l'activité en direct
    /// et les alertes de seuil quand l'app est fermée.
    static let defaultServerURL = "http://100.117.213.59:7110"

    static func pageURL(balise: Int) -> URL {
        URL(string: "https://www.balisemeteo.com/balise.php?idBalise=\(balise)")!
    }
}
