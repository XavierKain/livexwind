#!/usr/bin/env python3
"""
Source de données windmorbihan.com (baie de Quiberon, Bretagne sud).

Contrairement à balisemeteo.com, le site expose une vraie API JSON — pas besoin
de scraping :

  backend.windmorbihan.com/capteurs/list.json      liste des capteurs
  private2.windmorbihan.com/mesures/getlastalljson.json   dernier relevé de tous
  private2.windmorbihan.com/mesures/history.json          historique (~6 Mo)

Les vitesses sont publiées en nœuds ; on les convertit en km/h, l'unité interne
de LiveXWind. `history.json` ne sert qu'au premier remplissage d'une balise :
ensuite on accumule à partir de `getlastalljson.json`, bien plus léger.
"""

from __future__ import annotations

import json
import time
from datetime import datetime, timezone
from urllib.request import Request, urlopen

SENSORS_URL = "https://backend.windmorbihan.com/capteurs/list.json"
LATEST_URL = "https://private2.windmorbihan.com/mesures/getlastalljson.json"
HISTORY_URL = "https://private2.windmorbihan.com/mesures/history.json"

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
HEADERS = {"User-Agent": UA, "Referer": "https://www.windmorbihan.com/", "Accept": "application/json"}
KNOT_TO_KMH = 1.852

_cache: dict = {"latest": None, "latest_ts": 0.0, "sensors": None, "sensors_ts": 0.0}
LATEST_TTL = 45          # un seul appel réseau même avec plusieurs balises suivies
SENSORS_TTL = 6 * 3600

COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
           "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]


def _get_json(url: str, timeout: int = 30):
    with urlopen(Request(url, headers=HEADERS), timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def compass(degrees) -> str | None:
    if degrees is None:
        return None
    return COMPASS[int(round(float(degrees) / 22.5)) % 16]


def sensors(force: bool = False) -> list[dict]:
    """Capteurs de vent : identifiant, nom, position."""
    if not force and _cache["sensors"] and time.time() - _cache["sensors_ts"] < SENSORS_TTL:
        return _cache["sensors"]

    payload = _get_json(SENSORS_URL)
    wind = payload.get("sensors", {}).get("WindSensor", {})
    out = []
    for nid, s in wind.items():
        try:
            out.append({"id": int(nid),
                        "name": s.get("label") or f"Capteur {nid}",
                        "lat": s.get("lat"),
                        "lon": s.get("lng"),
                        "slug": s.get("slug")})
        except (TypeError, ValueError):
            continue
    out.sort(key=lambda s: s["name"])
    _cache.update(sensors=out, sensors_ts=time.time())
    return out


def _latest_map(force: bool = False) -> dict:
    if not force and _cache["latest"] and time.time() - _cache["latest_ts"] < LATEST_TTL:
        return _cache["latest"]
    rows = _get_json(LATEST_URL)
    mapped = {str(r.get("nid")): r for r in rows if r.get("nid") is not None}
    _cache.update(latest=mapped, latest_ts=time.time())
    return mapped


def _reading_from(row: dict) -> dict | None:
    """Traduit un relevé windmorbihan vers le format interne (km/h, ISO UTC)."""
    if not row:
        return None
    knots = row.get("wind_pow_knot")
    gust = row.get("wind_pow_knot_max")
    if knots is None and gust is None:
        return None

    # `created` est un dict {epoch: "libellé lisible"} ; l'epoch est la vérité.
    stamp = None
    created = row.get("created")
    if isinstance(created, dict) and created:
        try:
            stamp = int(next(iter(created)))
        except (TypeError, ValueError):
            stamp = None
    if stamp is None:
        stamp = int(time.time())

    direction = row.get("wind_dir_true")
    return {
        "t": datetime.fromtimestamp(stamp, timezone.utc).replace(second=0, microsecond=0)
                     .isoformat().replace("+00:00", "Z"),
        "dir": int(direction) % 360 if direction is not None else None,
        "dirLabel": compass(direction),
        "avg": round(knots * KNOT_TO_KMH, 1) if knots is not None else None,
        "gust": round(gust * KNOT_TO_KMH, 1) if gust is not None else None,
        "gustDir": None,
        "min": None,
        "temp": row.get("t"),
        "lum": None,
        "stale": False,
    }


def latest(nid: int, force: bool = False) -> dict | None:
    return _reading_from(_latest_map(force=force).get(str(nid)))


def history(nid: int, limit_hours: int = 48) -> list[dict]:
    """Historique complet — appelé une seule fois, au premier suivi d'une balise."""
    try:
        payload = _get_json(HISTORY_URL, timeout=90)
    except Exception:
        return []

    cutoff = time.time() - limit_hours * 3600
    samples = []
    for ts, per_sensor in payload.items():
        row = per_sensor.get(str(nid))
        if not row:
            continue
        try:
            stamp = int(ts)
        except (TypeError, ValueError):
            continue
        if stamp < cutoff:
            continue
        knots, gust = row.get("wind_pow_knot"), row.get("wind_pow_knot_max")
        if knots is None and gust is None:
            continue
        samples.append({
            "t": datetime.fromtimestamp(stamp, timezone.utc).replace(second=0, microsecond=0)
                         .isoformat().replace("+00:00", "Z"),
            "dir": int(row["wind_dir_true"]) % 360 if row.get("wind_dir_true") is not None else None,
            "avg": round(knots * KNOT_TO_KMH, 1) if knots is not None else None,
            "gust": round(gust * KNOT_TO_KMH, 1) if gust is not None else None,
            "min": None,
            "temp": row.get("t"),
        })
    samples.sort(key=lambda s: s["t"])
    return samples


def balise_info(nid: int) -> dict | None:
    for s in sensors():
        if s["id"] == nid:
            return {"id": nid, "name": s["name"], "lat": s["lat"], "lon": s["lon"],
                    "altitude": None,
                    "url": f"https://www.windmorbihan.com/?spot={s.get('slug') or nid}"}
    return None


if __name__ == "__main__":
    import sys
    nid = int(sys.argv[1]) if len(sys.argv) > 1 else 73091277
    info = balise_info(nid)
    print("balise :", info)
    print("relevé :", latest(nid))
    h = history(nid)
    print(f"historique : {len(h)} points", h[-1] if h else "")
