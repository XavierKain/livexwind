#!/usr/bin/env python3
"""
Source windguru.cz — des milliers de stations dans le monde, toutes sur le même
modèle. C'est ce qui permet d'ajouter Tarifa / Campo de Futbol (station 2667).

Trois points d'entrée publics suffisent :

  int/iapi.php?q=station&id_station=N&weather=false     fiche de la station
  int/iapi.php?q=station_data_current&id_station=N      relevé courant
  int/iapi.php?q=station_data&id_station=N&from=&to=    historique

Les vitesses sont en **nœuds** (vérifié : la page affiche « 0.8 knots / max 2.5 »
quand l'API renvoie wind_avg 0.8 / wind_max 2.5). On convertit en km/h, l'unité
interne de LiveXWind.

La recherche de stations de windguru, elle, exige un compte. On tient donc notre
propre index : un balayage lent et repris d'exécution en exécution des fiches
`q=station`, qui alimente une recherche locale instantanée.
"""

from __future__ import annotations

import json
import logging
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen

log = logging.getLogger("livexwind.windguru")

BASE = "https://www.windguru.cz/int/iapi.php"
HEADERS = {
    "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
    "Referer": "https://www.windguru.cz/",
    "Accept": "application/json",
}
KNOT_TO_KMH = 1.852

# Bornes observées : les identifiants vont de 1 à ~13 000, avec des trous.
INDEX_MAX_ID = 13500
INDEX_PATH = Path.home() / "xklip" / "data" / "windguru_index.json"

COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
           "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]


# --- Refus de la source -----------------------------------------------------
#
# windguru nous a fermé `iapi.php` le 25/09/2026 : HTTP 403 « forbidden » sur
# chaque appel, alors que les pages HTML continuaient de répondre. Nos appels se
# comptaient en milliers par jour — deux par relevé et par balise, plus vingt par
# affichage de carte. Personne ne l'a vu pendant quatorze jours : `_get` avalait
# l'exception, `latest()` renvoyait None, et le serveur se contentait de
# reconduire un flux figé.
#
# Deux conséquences tirées de là : on le dit, et on cesse de frapper à une porte
# qu'on vient de nous fermer.

REFUSAL_CODES = (401, 403, 429)
MUTE_AFTER_REFUSAL = 600     # on laisse la source respirer avant de réessayer
STATION_TTL = 24 * 3600      # nom, position, altitude : ça ne bouge pas

_refusal: dict = {"message": None, "since": None, "count": 0, "muted_until": 0.0}
_station_cache: dict = {}


def status() -> dict:
    """État de la source, tel que /api/health doit pouvoir le montrer."""
    if not _refusal["message"]:
        return {"ok": True}
    return {"ok": False,
            "message": _refusal["message"],
            "since": _refusal["since"],
            "count": _refusal["count"],
            "muted_for": max(0, int(_refusal["muted_until"] - time.time()))}


def available() -> bool:
    """Faux tant que la source vient de nous refuser l'accès."""
    return time.time() >= _refusal["muted_until"]


def _note(exc: Exception, what: str):
    message = f"HTTP {exc.code}" if isinstance(exc, HTTPError) else f"{type(exc).__name__}: {exc}"
    refused = isinstance(exc, HTTPError) and exc.code in REFUSAL_CODES
    first = _refusal["message"] != message
    _refusal["message"] = message
    _refusal["count"] = 1 if first else _refusal["count"] + 1
    if first:
        _refusal["since"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    if refused:
        _refusal["muted_until"] = time.time() + MUTE_AFTER_REFUSAL
    # Bruyant la première fois, discret ensuite : le journal doit porter le
    # diagnostic sans se remplir d'une ligne toutes les 25 secondes.
    (log.warning if first else log.debug)(
        "windguru refuse %s (%s) — %de fois depuis %s",
        what, message, _refusal["count"], _refusal["since"])


def _clear():
    if _refusal["message"]:
        log.warning("windguru répond de nouveau (après %d refus)", _refusal["count"])
    _refusal.update(message=None, since=None, count=0, muted_until=0.0)


def _get(params: str, timeout: int = 25):
    with urlopen(Request(f"{BASE}?{params}", headers=HEADERS), timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def compass(degrees) -> str | None:
    if degrees is None:
        return None
    return COMPASS[int(round(float(degrees) / 22.5)) % 16]


def _label(payload: dict) -> str:
    """« Tarifa — Campo de Futbol » plutôt que l'un ou l'autre."""
    spot = (payload.get("spotname") or "").strip()
    name = (payload.get("name") or "").strip()
    if spot and name and spot.lower() not in name.lower():
        return f"{spot} — {name}"
    return name or spot or f"Station {payload.get('id_station')}"


def station(station_id: int) -> dict | None:
    """Fiche de la station, ou None si l'identifiant n'existe pas.

    Gardée en cache : le nom, la position et l'altitude d'une station ne
    changent pas, et la redemander à chaque relevé doublait sans rien y gagner
    le nombre d'appels à une API qui n'est pas la nôtre.
    """
    cached = _station_cache.get(station_id)
    if cached and time.time() - cached[0] < STATION_TTL:
        return cached[1]
    if not available():
        return None
    try:
        payload = _get(f"q=station&id_station={station_id}&weather=false")
        _clear()
    except Exception as exc:
        _note(exc, f"la fiche de la station {station_id}")
        return None
    if not isinstance(payload, dict) or not payload.get("id_station"):
        return None
    fiche = {
        "id": int(payload["id_station"]),
        "name": _label(payload),
        "lat": payload.get("lat"),
        "lon": payload.get("lon"),
        "altitude": payload.get("alt"),
        "url": f"https://www.windguru.cz/station/{station_id}",
    }
    _station_cache[station_id] = (time.time(), fiche)
    return fiche


def _reading(avg, mx, mn, direction, temp, stamp: float, pressure=None) -> dict:
    return {
        "t": datetime.fromtimestamp(stamp, timezone.utc).replace(second=0, microsecond=0)
                     .isoformat().replace("+00:00", "Z"),
        "dir": int(direction) % 360 if direction is not None else None,
        "dirLabel": compass(direction),
        "avg": round(avg * KNOT_TO_KMH, 1) if avg is not None else None,
        "gust": round(mx * KNOT_TO_KMH, 1) if mx is not None else None,
        "gustDir": None,
        "min": round(mn * KNOT_TO_KMH, 1) if mn is not None else None,
        "temp": temp,
        "pressure": pressure,
        "lum": None,
        "stale": False,
    }


def latest(station_id: int) -> dict | None:
    if not available():
        return None
    try:
        d = _get(f"q=station_data_current&id_station={station_id}")
        _clear()
    except Exception as exc:
        _note(exc, f"le relevé de la station {station_id}")
        return None
    if not isinstance(d, dict) or d.get("wind_avg") is None:
        return None
    return _reading(d.get("wind_avg"), d.get("wind_max"), d.get("wind_min"),
                    d.get("wind_direction"), d.get("temperature"),
                    d.get("unixtime") or time.time(), pressure=d.get("mslp"))


def history(station_id: int, hours: int = 48) -> list[dict]:
    """Historique — appelé au premier suivi, puis on accumule sur les relevés."""
    now = datetime.now(timezone.utc)
    frm = quote((now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S.000Z"), safe="")
    to = quote(now.strftime("%Y-%m-%dT%H:%M:%S.000Z"), safe="")
    if not available():
        return []
    try:
        d = _get(f"q=station_data&id_station={station_id}&from={frm}&to={to}&avg_minutes=10", timeout=45)
        _clear()
    except Exception as exc:
        _note(exc, f"l'historique de la station {station_id}")
        return []

    stamps = d.get("unixtime") or []
    avg, mx, mn = d.get("wind_avg") or [], d.get("wind_max") or [], d.get("wind_min") or []
    directions, temps = d.get("wind_direction") or [], d.get("temperature") or []

    def at(seq, i):
        return seq[i] if i < len(seq) else None

    out = []
    for i, stamp in enumerate(stamps):
        sample = _reading(at(avg, i), at(mx, i), at(mn, i), at(directions, i), at(temps, i), stamp)
        sample.pop("stale", None)
        sample.pop("lum", None)
        sample.pop("dirLabel", None)
        sample.pop("gustDir", None)
        if sample["avg"] is not None or sample["gust"] is not None:
            out.append(sample)
    return out


# --------------------------------------------------------------------- index

def load_index() -> dict:
    try:
        return json.loads(INDEX_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"next_id": 1, "stations": {}, "updated": None}


def save_index(index: dict):
    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = INDEX_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(index, ensure_ascii=False))
    tmp.replace(INDEX_PATH)


def index_step(batch: int = 40, pause: float = 0.7) -> dict:
    """Indexe un petit lot de stations. Appelé en boucle, lentement, en tâche de fond.

    Le balayage est volontairement lent : c'est une courtoisie vis-à-vis de
    windguru, et l'index se conserve d'une exécution à l'autre.
    """
    index = load_index()
    start = index.get("next_id", 1)
    if start > INDEX_MAX_ID:
        return index

    for station_id in range(start, min(start + batch, INDEX_MAX_ID + 1)):
        info = station(station_id)
        if info:
            index["stations"][str(station_id)] = {
                "id": info["id"], "name": info["name"],
                "lat": info["lat"], "lon": info["lon"], "altitude": info["altitude"],
            }
        index["next_id"] = station_id + 1
        time.sleep(pause)

    index["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    save_index(index)
    return index


def search(query: str, limit: int = 40) -> list[dict]:
    """Recherche dans l'index local — insensible à la casse et aux accents."""
    import unicodedata

    def fold(text: str) -> str:
        return "".join(c for c in unicodedata.normalize("NFD", text.lower())
                       if unicodedata.category(c) != "Mn")

    needle = fold(query.strip())
    if not needle:
        return []
    stations = load_index().get("stations", {})
    hits = [s for s in stations.values() if needle in fold(s["name"])]
    hits.sort(key=lambda s: (not fold(s["name"]).startswith(needle), s["name"]))
    return hits[:limit]


def nearby(lat: float, lon: float, radius_km: float = 60, limit: int = 30) -> list[dict]:
    """Stations de l'index les plus proches d'un point, triées par distance.

    Windguru n'ouvre sa recherche qu'aux comptes, mais notre index garde la
    position de chaque station : la proximité se calcule chez nous.
    """
    import math

    def distance_km(lat1, lon1, lat2, lon2):
        r = 6371.0
        p1, p2 = math.radians(lat1), math.radians(lat2)
        dp = math.radians(lat2 - lat1)
        dl = math.radians(lon2 - lon1)
        a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
        return 2 * r * math.asin(math.sqrt(a))

    hits = []
    for station_info in load_index().get("stations", {}).values():
        s_lat, s_lon = station_info.get("lat"), station_info.get("lon")
        if s_lat is None or s_lon is None:
            continue
        km = distance_km(lat, lon, s_lat, s_lon)
        if km <= radius_km:
            hits.append({**station_info, "km": round(km, 1)})
    hits.sort(key=lambda s: s["km"])
    return hits[:limit]


def index_progress() -> dict:
    index = load_index()
    return {"indexed": len(index.get("stations", {})),
            "scanned": index.get("next_id", 1) - 1,
            "total": INDEX_MAX_ID,
            "updated": index.get("updated")}


if __name__ == "__main__":
    import sys
    sid = int(sys.argv[1]) if len(sys.argv) > 1 else 2667
    print("station   :", station(sid))
    print("relevé    :", latest(sid))
    h = history(sid)
    print(f"historique: {len(h)} points", h[-1] if h else "")
    print("index     :", index_progress())
