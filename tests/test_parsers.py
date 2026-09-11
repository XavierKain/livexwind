#!/usr/bin/env python3
"""
Garde-fou des parseurs.

Les trois sources peuvent changer de format sans prévenir. Quand ça arrive,
l'app ne plante pas : elle retombe sur le cache et affiche des données périmées
sans rien dire. Ces tests, joués sur des réponses réelles enregistrées, font
échouer la CI avant que ça n'arrive en silence.

    python3 -m unittest discover -s tests
"""

import json
import pathlib
import sys
import unittest
from datetime import timezone

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "feed"))
FIXTURES = ROOT / "tests" / "fixtures"

import scrape          # noqa: E402
import windmorbihan    # noqa: E402
import windguru        # noqa: E402


def fixture(name: str) -> str:
    return (FIXTURES / name).read_text(encoding="utf-8")


class BalisemeteoTests(unittest.TestCase):
    """balisemeteo.com — page HTML, valeurs dans un tableau."""

    def setUp(self):
        self.parsed = scrape.parse(fixture("balisemeteo_64.html"), 64)

    def test_identite_de_la_balise(self):
        balise = self.parsed["balise"]
        self.assertEqual(balise["id"], 64)
        self.assertEqual(balise["name"], "Pyla Pilat")
        self.assertEqual(balise["altitude"], 55)
        self.assertAlmostEqual(balise["lat"], 44.5761111, places=4)
        self.assertAlmostEqual(balise["lon"], -1.2247222, places=4)

    def test_valeurs_de_vent(self):
        reading = self.parsed["reading"]
        self.assertFalse(reading["stale"])
        for champ in ("avg", "gust", "dir"):
            self.assertIsNotNone(reading[champ], f"{champ} devrait être lu")
        self.assertGreaterEqual(reading["avg"], 0)
        self.assertGreaterEqual(reading["gust"], reading["avg"] - 0.001,
                                "la rafale ne peut pas être sous le vent moyen")
        self.assertIn(reading["dir"], range(360))

    def test_horodatage_converti_en_utc(self):
        reading = self.parsed["reading"]
        self.assertTrue(reading["t"].endswith("Z"), "l'heure doit être en UTC")
        # Le site publie en heure de Paris ; en septembre c'est UTC+2.
        self.assertRegex(reading["t"], r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00Z$")

    def test_page_masquee_est_signalee(self):
        parsed = scrape.parse(fixture("balisemeteo_64_masked.html"), 64)
        self.assertTrue(parsed["reading"]["stale"],
                        "une page masquée doit être signalée, pas lue comme un zéro")
        self.assertIsNone(parsed["reading"]["avg"])


class WindmorbihanTests(unittest.TestCase):
    """windmorbihan.com — API JSON, vitesses en nœuds."""

    def setUp(self):
        self.rows = json.loads(fixture("windmorbihan_latest.json"))
        self.sensors = json.loads(fixture("windmorbihan_sensors.json"))

    def test_capteurs_identifies(self):
        noms = {s["name"] for s in self.sensors}
        self.assertIn("Semaphore d'Etel", noms)
        self.assertTrue(all(s.get("lat") and s.get("lon") for s in self.sensors),
                        "chaque capteur doit avoir une position")

    def test_conversion_noeuds_vers_kmh(self):
        brut = self.rows["73091277"]
        lecture = windmorbihan._reading_from(brut)
        self.assertIsNotNone(lecture)
        attendu = round(brut["wind_pow_knot"] * 1.852, 1)
        self.assertAlmostEqual(lecture["avg"], attendu, places=1)
        self.assertEqual(lecture["dir"], int(brut["wind_dir_true"]) % 360)

    def test_capteur_sans_donnee(self):
        self.assertIsNone(windmorbihan._reading_from({"nid": 1}))
        self.assertIsNone(windmorbihan._reading_from(None))


class WindguruTests(unittest.TestCase):
    """windguru.cz — API JSON, vitesses en nœuds elles aussi."""

    def test_fiche_station(self):
        info = json.loads(fixture("windguru_station_2667.json"))
        self.assertEqual(info["id"], 2667)
        self.assertIn("Campo de Futbol", info["name"])
        self.assertIn("Tarifa", info["name"])

    def test_conversion_du_releve(self):
        brut = json.loads(fixture("windguru_current_2667.json"))
        lecture = windguru._reading(brut["wind_avg"], brut["wind_max"], brut["wind_min"],
                                   brut["wind_direction"], brut["temperature"], brut["unixtime"])
        self.assertAlmostEqual(lecture["avg"], round(brut["wind_avg"] * 1.852, 1), places=1)
        self.assertAlmostEqual(lecture["gust"], round(brut["wind_max"] * 1.852, 1), places=1)
        self.assertTrue(lecture["t"].endswith("Z"))


class HistoriqueTests(unittest.TestCase):
    """Une station à la minute ne doit pas produire un flux de 300 Ko."""

    def test_detail_conserve_sur_les_dernieres_heures(self):
        from cadence import thin_history
        from datetime import datetime, timedelta, timezone

        now = datetime(2026, 9, 7, 12, 0, tzinfo=timezone.utc)
        # 48 h de relevés à la minute, comme en publie windguru.
        history = [{"t": (now - timedelta(minutes=i)).isoformat().replace("+00:00", "Z"),
                    "avg": 20.0} for i in range(48 * 60, 0, -1)]

        thinned = thin_history(history, now=now)
        self.assertLess(len(thinned), 500, "l'historique doit être allégé")

        recents = [s for s in thinned
                   if (now - datetime.fromisoformat(s["t"].replace("Z", "+00:00"))).total_seconds() <= 3 * 3600]
        self.assertGreaterEqual(len(recents), 175,
                                "les 3 dernières heures gardent leur résolution")

    def test_historique_vide(self):
        from cadence import thin_history
        self.assertEqual(thin_history([]), [])


class RoseDesVentsTests(unittest.TestCase):
    """La rose est partagée : une erreur de secteur fausserait les alertes."""

    def test_secteurs(self):
        for degres, attendu in [(0, "N"), (90, "E"), (180, "S"), (270, "O"),
                                (359, "N"), (45, "NE"), (225, "SO")]:
            self.assertEqual(windguru.compass(degres), attendu, f"{degres}°")
            self.assertEqual(windmorbihan.compass(degres), attendu, f"{degres}°")

    def test_absence_de_direction(self):
        self.assertIsNone(windguru.compass(None))


class CadenceTests(unittest.TestCase):
    """La cadence est déduite du plus petit écart : un trou ne doit pas la fausser."""

    def test_plus_petit_ecart_retenu(self):
        from cadence import observed_period
        historique = [{"t": t} for t in (
            "2026-09-01T10:00:00Z", "2026-09-01T10:01:00Z",
            "2026-09-01T10:02:00Z", "2026-09-01T10:12:00Z",  # trou de transmission
            "2026-09-01T10:13:00Z",
        )]
        self.assertEqual(observed_period(historique), 60)

    def test_pas_semi_horaire(self):
        """meteo.cat publie toutes les 30 min : la cadence doit être mesurée, pas écartée."""
        from cadence import observed_period
        historique = [{"t": t} for t in (
            "2026-09-01T10:00:00Z", "2026-09-01T10:30:00Z", "2026-09-01T11:00:00Z",
        )]
        self.assertEqual(observed_period(historique), 1800)

    def test_repli_quand_l_historique_est_trop_court(self):
        from cadence import observed_period
        self.assertEqual(observed_period([]), 600)


if __name__ == "__main__":
    unittest.main(verbosity=2)


class DoublonsTests(unittest.TestCase):
    """Plusieurs fiches pour un même anémomètre : cas observé à Tarifa."""

    def setUp(self):
        from duplicates import group
        self.group = group
        # Relevés réels du 2026-09-11 : trois fiches KWind et une Windguru pour
        # le même capteur, plus une station voisine réellement distincte.
        self.stations = [
            {"name": "Balneario A", "lat": 36.00690, "lon": -5.60824, "t": "2026-09-11T12:52:22Z",
             "temp": 26.2, "pressure": 1020.4, "raw_avg": 18.3, "raw_gust": 28.8, "offset": 1.5},
            {"name": "Balneario B", "lat": 36.00801, "lon": -5.60739, "t": "2026-09-11T12:52:22Z",
             "temp": 26.2, "pressure": 1020.4, "raw_avg": 18.3, "raw_gust": 28.8, "offset": 2.3},
            {"name": "Tarifa", "lat": 36.00674, "lon": -5.60835, "t": "2026-09-11T12:52:22Z",
             "temp": 26.2, "pressure": 1020.4, "raw_avg": 18.3, "raw_gust": 28.8, "offset": 1.33},
            {"name": "Campo de Futbol", "lat": 36.02441, "lon": -5.61349, "t": "2026-09-11T12:53:23Z",
             "temp": 26.2, "pressure": 1020.3, "raw_avg": None, "raw_gust": None, "offset": None},
            {"name": "Los Lances", "lat": 36.04839, "lon": -5.64327, "t": "2026-09-11T12:52:24Z",
             "temp": 26.9, "pressure": None, "raw_avg": 6.87, "raw_gust": 11.26, "offset": None},
        ]

    def test_les_quatre_fiches_forment_un_groupe(self):
        result = self.group(self.stations)
        groupes = {s["name"]: s["sensor_group"] for s in result}
        self.assertEqual(groupes["Balneario A"], groupes["Balneario B"])
        self.assertEqual(groupes["Balneario A"], groupes["Tarifa"])
        self.assertEqual(groupes["Balneario A"], groupes["Campo de Futbol"],
                         "le même capteur alimente KWind et Windguru")

    def test_une_station_distincte_reste_seule(self):
        result = self.group(self.stations)
        seule = next(s for s in result if s["name"] == "Los Lances")
        self.assertIsNone(seule["sensor_group"])
        self.assertTrue(seule["is_primary"])

    def test_la_representante_est_la_moins_corrigee(self):
        result = self.group(self.stations)
        primaires = [s["name"] for s in result if s["sensor_group"] and s["is_primary"]]
        self.assertEqual(primaires, ["Campo de Futbol"],
                         "la fiche sans correction est la plus proche du capteur")
