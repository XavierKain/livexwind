import Foundation

enum AppConfig {
    /// Balise FFVL suivie par défaut — Pyla / Dune du Pilat.
    static let baliseID = 64
    static let widgetKind = "LiveXWindWidget"

    /// Historique publié par le serveur sur GitHub Pages, une balise par fichier.
    static func feedURL(key: String) -> URL {
        URL(string: "https://xavierkain.github.io/livexwind/balise-\(key).json")!
    }

    /// Serveur de push (Tailscale) : c'est lui qui pousse l'activité en direct
    /// et les alertes de seuil quand l'app est fermée.
    static let defaultServerURL = "http://100.117.213.59:7110"

    /// Miroir HTTPS public, écrit à chaque relevé. C'est le seul chemin de
    /// l'Apple Watch, qui n'est pas sur le réseau Tailscale, et le secours de
    /// l'iPhone quand le VPN est coupé.
    static let publicMirror = URL(string: "https://livexwind.49.13.25.233.sslip.io")!

    static func publicFeedURL(key: String) -> URL {
        publicMirror.appendingPathComponent("balise-\(key).json")
    }

    /// Balise affichée sur l'iPhone — la montre s'y accroche.
    static var selectedPointerURL: URL {
        publicMirror.appendingPathComponent("selected.json")
    }

    static func pageURL(balise: Int) -> URL {
        URL(string: "https://www.balisemeteo.com/balise.php?idBalise=\(balise)")!
    }
}
