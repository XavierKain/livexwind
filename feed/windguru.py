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
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote
from urllib.request import Request, urlopen

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
    """Fiche de la station, ou None si l'identifiant n'existe pas."""
    try:
        payload = _get(f"q=station&id_station={station_id}&weather=false")
    except Exception:
        return None
    if not isinstance(payload, dict) or not payload.get("id_station"):
        return None
    return {
        "id": int(payload["id_station"]),
        "name": _label(payload),
        "lat": payload.get("lat"),
        "lon": payload.get("lon"),
        "altitude": payload.get("alt"),
        "url": f"https://www.windguru.cz/station/{station_id}",
    }


def _reading(avg, mx, mn, direction, temp, stamp: float) -> dict:
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
        "lum": None,
        "stale": False,
    }


def latest(station_id: int) -> dict | None:
    try:
        d = _get(f"q=station_data_current&id_station={station_id}")
    except Exception:
        return None
    if not isinstance(d, dict) or d.get("wind_avg") is None:
        return None
    return _reading(d.get("wind_avg"), d.get("wind_max"), d.get("wind_min"),
                    d.get("wind_direction"), d.get("temperature"),
                    d.get("unixtime") or time.time())


def history(station_id: int, hours: int = 48) -> list[dict]:
    """Historique — appelé au premier suivi, puis on accumule sur les relevés."""
    now = datetime.now(timezone.utc)
    frm = quote((now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%S.000Z"), safe="")
    to = quote(now.strftime("%Y-%m-%dT%H:%M:%S.000Z"), safe="")
    try:
        d = _get(f"q=station_data&id_station={station_id}&from={frm}&to={to}&avg_minutes=10", timeout=45)
    except Exception:
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
