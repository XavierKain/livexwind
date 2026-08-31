# LiveXWind

Vent live de la balise FFVL **Pyla / Dune du Pilat** ([balise 64](https://www.balisemeteo.com/balise.php?idBalise=64)) sur iPhone : app, widgets écran d'accueil / écran verrouillé, et activité en direct (Dynamic Island).

## Ce que ça fait

- **Relevé live** : vent moyen, rafales, mini, direction (rose des vents + degrés), température.
- **Graphe d'évolution** : force moyenne, rafales, et flèches de direction sur 3 / 6 / 12 / 24 h.
- **km/h ⇄ nœuds** : bascule instantanée dans l'app, et paramètre par widget (appui long → *Modifier le widget*).
- **Widgets** : petit, moyen, grand, plus rectangulaire / circulaire / inline sur l'écran verrouillé.
- **Activité en direct** : vent sur l'écran verrouillé et l'île dynamique, avec mini-courbe.
- **Alertes de seuil** : notification quand le vent franchit un seuil haut (ça monte) ou retombe sous
  un seuil bas, au choix sur le vent moyen ou les rafales, avec plage horaire et anti-spam.
  Elles sont évaluées à chaque relevé lu par l'app et à chaque réveil `BGAppRefreshTask` —
  iOS fixe la cadence de ces réveils, une alerte peut donc arriver au relevé suivant.

## Rythme de mise à jour

La balise publie un relevé **toutes les 10 minutes**. L'app lit l'heure du dernier relevé et se recale
sur cette grille : prochaine lecture à `dernier relevé + 10 min + 45 s`, donc au plus tard une minute
après la publication. Le widget demande le même horaire à WidgetKit (iOS peut espacer davantage
si le widget est peu consulté — c'est un plafond système, pas un choix de l'app).

## Comment la donnée est récupérée

`balisemeteo.com` masque les valeurs (`!!! WARNING !!!`) tant que le client n'a pas de session PHP.
`BaliseClient` fait donc une requête d'amorçage sur l'accueil pour obtenir le cookie, puis lit la fiche
balise et parse le tableau HTML. Le site ne publiant l'historique qu'en images PNG,
`.github/workflows/feed.yml` scrape la balise toutes les 10 min et publie
`docs/balise-64.json` (48 h d'historique) sur GitHub Pages ; l'app y récupère la courbe et s'en sert
aussi de secours si le scraping direct échoue.

## Push APNs (serveur)

`server/livexwind_server.py` tourne en systemd sur le serveur Hetzner (`livexwind.service`,
port 7110, joint depuis l'iPhone par Tailscale : `http://100.117.213.59:7110`). Il fait deux choses :

- **API d'enregistrement** — l'app y dépose son token d'activité en direct, son token
  *push-to-start* (iOS 17.2+), son token d'appareil et ses seuils d'alerte.
- **Pousseur** — il suit la balise et, dès qu'un relevé tombe, envoie l'update de l'activité
  en direct, relance celle-ci si iOS l'a coupée (limite de 8 h), et envoie l'alerte de seuil.

Résultat : l'activité en direct et les alertes ne dépendent plus des réveils en arrière-plan
d'iOS. Hors Tailscale, l'app le détecte et repasse en notifications locales.

Config : `~/xklip/config/livexwind.json` (team ID, key ID APNs, chemin du `.p8`, bundle ID).
Le JWT ES256 est signé directement avec `cryptography` — pas de dépendance PyJWT.

## Structure

```
App/        app SwiftUI (dial, graphe, activité en direct, réveil BGTask)
Widget/     extension WidgetKit + activité en direct
Shared/     modèles, client balise, vues partagées, intent de configuration
feed/       scraper Python partagé (GitHub Actions + serveur)
server/     API d'enregistrement + pousseur APNs (systemd)
fastlane/   build signé + upload TestFlight
docs/       flux JSON publié sur GitHub Pages
```

Le projet Xcode est généré par [XcodeGen](https://github.com/yonaskolb/XcodeGen) depuis `project.yml` — il n'est pas versionné.

## Build & livraison

- `Build (contrôle sans signature)` : compile à chaque push sur `main`.
- `TestFlight` : lancement manuel (`Actions > TestFlight > Run workflow`), build signé via `match` + upload.

Secrets requis : `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8_BASE64`, `MATCH_PASSWORD`.

Les bundle IDs sont créés automatiquement par la lane. Seule étape manuelle, une seule fois :
créer la fiche de l'app dans App Store Connect (Apps > + > Nouvelle app, iOS, nom *LiveXWind*,
bundle ID `com.xavierkain.livexwind`, SKU `livexwind`) — l'API Apple n'expose pas `POST /v1/apps`.

Données : balisemeteo.com / FFVL.
