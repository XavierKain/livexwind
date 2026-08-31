import Foundation

enum AppConfig {
    /// Balise FFVL suivie par défaut — Pyla / Dune du Pilat.
    static let baliseID = 64
    static let widgetKind = "LiveXWindWidget"

    /// Historique publié toutes les 10 min par GitHub Actions (GitHub Pages).
    static let feedURL = URL(string: "https://xavierkain.github.io/livexwind/balise-64.json")!

    /// Serveur de push (Tailscale) : c'est lui qui pousse l'activité en direct
    /// et les alertes de seuil quand l'app est fermée.
    static let defaultServerURL = "http://100.117.213.59:7110"

    static var pageURL: URL {
        URL(string: "https://www.balisemeteo.com/balise.php?idBalise=\(baliseID)")!
    }
}
