#!/usr/bin/env python3
"""
Repère les balises qui partagent un même capteur physique.

Autour de Tarifa, plusieurs balises publient des relevés identiques à la décimale
et à la seconde près, avec des coordonnées écartées de cent mètres et une valeur
de vent décalée d'un ou deux nœuds. Observé le 2026-09-11 :

  KWind « Balneario Tarifa »    brut 18.3 / 28.8, T 26.2, P 1020.4, 12:52:22, +1.5
  KWind « Balneario Tarifa »    brut 18.3 / 28.8, T 26.2, P 1020.4, 12:52:22, +2.3
  KWind « Tarifa »              brut 18.3 / 28.8, T 26.2, P 1020.4, 12:52:22, +1.33
  Windguru « Campo de Futbol »       18.3,        T 26.2, P 1020.3, 12:53:23

Un seul anémomètre, quatre fiches. Chez KWind, l'écart vient d'une correction
d'étalonnage choisie par le propriétaire (champ `formula`) ; entre réseaux, le
même capteur alimente simplement les deux.

La température et la pression font une bien meilleure empreinte que le vent :
elles ne dépendent pas de la fenêtre de moyennage, qui diffère d'un réseau à
l'autre pour une même mesure brute.
"""

from __future__ import annotations

import math
from datetime import datetime

# Tolérances de l'empreinte. Volontairement serrées : mieux vaut laisser passer
# un doublon que déclarer identiques deux capteurs voisins mais distincts.
MAX_DISTANCE_KM = 2.0
MAX_TEMP_DELTA = 0.2
MAX_PRESSURE_DELTA = 0.4
MAX_TIME_DELTA_S = 240


def _epoch(stamp) -> float | None:
    if not stamp:
        return None
    try:
        return datetime.fromisoformat(str(stamp).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _distance_km(a: dict, b: dict) -> float:
    if None in (a.get("lat"), a.get("lon"), b.get("lat"), b.get("lon")):
        return 1e9
    r = 6371.0
    p1, p2 = math.radians(a["lat"]), math.radians(b["lat"])
    dp = math.radians(b["lat"] - a["lat"])
    dl = math.radians(b["lon"] - a["lon"])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def _close(x, y, tolerance) -> bool:
    return x is not None and y is not None and abs(x - y) <= tolerance


def same_sensor(a: dict, b: dict) -> bool:
    """Deux fiches décrivent-elles le même capteur ?

    Chaque fiche attend : lat, lon, t (ISO), temp, pressure, raw_avg, raw_gust.
    """
    if _distance_km(a, b) > MAX_DISTANCE_KM:
        return False

    ta, tb = _epoch(a.get("t")), _epoch(b.get("t"))
    if ta is None or tb is None or abs(ta - tb) > MAX_TIME_DELTA_S:
        return False

    # Empreinte forte : même température **et** même pression. À deux kilomètres,
    # deux capteurs distincts lisent souvent la même température au dixième —
    # elle ne suffit donc pas à conclure seule.
    if (_close(a.get("temp"), b.get("temp"), MAX_TEMP_DELTA)
            and _close(a.get("pressure"), b.get("pressure"), MAX_PRESSURE_DELTA)):
        return True

    # À défaut, mesure brute rigoureusement identique — le cas de deux fiches
    # KWind qui republient le même flux avec des corrections différentes.
    if (a.get("raw_avg") is not None and b.get("raw_avg") is not None
            and _close(a["raw_avg"], b["raw_avg"], 0.01)
            and _close(a.get("temp"), b.get("temp"), MAX_TEMP_DELTA)):
        return True

    return False


def group(stations: list[dict]) -> list[dict]:
    """Assigne un identifiant de groupe aux fiches partageant un capteur.

    Chaque station reçoit `sensor_group` (None si elle est seule) et
    `is_primary` : une seule fiche par groupe est retenue comme représentante,
    celle dont la correction est la plus faible — donc la plus proche de la
    mesure du capteur.
    """
    groups: list[list[dict]] = []
    for station in stations:
        for bucket in groups:
            if any(same_sensor(station, other) for other in bucket):
                bucket.append(station)
                break
        else:
            groups.append([station])

    for index, bucket in enumerate(groups):
        if len(bucket) == 1:
            bucket[0]["sensor_group"] = None
            bucket[0]["is_primary"] = True
            continue

        # La plus proche du capteur : correction la plus faible, à défaut la
        # fiche qui publie une mesure brute.
        def calibration(station: dict) -> float:
            offset = station.get("offset")
            return abs(offset) if offset is not None else 0.0

        primary = min(bucket, key=lambda s: (calibration(s), s.get("name") or ""))
        for station in bucket:
            station["sensor_group"] = f"g{index}"
            station["is_primary"] = station is primary
            station["sensor_count"] = len(bucket)
    return stations
