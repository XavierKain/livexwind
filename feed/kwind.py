#!/usr/bin/env python3
"""
Source kwind.app — stations Ecowitt de la communauté kite, dont Tarifa.

Contrairement aux autres sources, kwind ne publie ni page lisible ni API REST :
son serveur HTTP ne fait qu'écho, tout passe par une **WebSocket** à la racine de
`api.kwind.app`, avec un sous-protocole versionné et un protocole applicatif en
JSON simple :

    → {"action":"identify","data":{...}}
    → {"action":"subscribe","channel":{"name":"station","params":{"where":{"_id":…}}}}
    ← {"data":{…, "lastWindData":{…}}}

Canaux utilisés : `station` (fiche + dernier relevé), `winddata` (historique),
`stations` (catalogue complet, pour la recherche).

Les vitesses sont en **nœuds** — vérifié en comparant à la station Windguru
voisine de Tarifa : 16,5 chez kwind pour 30,6 km/h chez Windguru, températures
identiques. On convertit en km/h, l'unité interne de LiveXWind.

Chaque station peut porter une correction d'étalonnage définie par son
propriétaire (`windspeedAdjusted`, formule « +1.5 »). L'app kwind affiche la
valeur corrigée quand elle existe : on fait pareil, sinon on n'afficherait pas
la même chose que le site.
"""

from __future__ import annotations

import asyncio
import json
import time
from datetime import datetime, timedelta, timezone

import websockets

WS_URL = "wss://api.kwind.app?deviceUUID=livexwind"
SUBPROTOCOL = "2.11.0"
ORIGIN = "https://kwind.app"
KNOT_TO_KMH = 1.852

COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
           "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]

_stations_cache: dict = {"list": None, "ts": 0.0}
STATIONS_TTL = 6 * 3600


def compass(degrees) -> str | None:
    if degrees is None:
        return None
    return COMPASS[int(round(float(degrees) / 22.5)) % 16]


# ------------------------------------------------------------------ transport

async def _query_async(channel: str, params: dict, timeout: float = 20):
    """Ouvre la socket, s'abonne, prend la première charge utile et referme.

    kwind est fait pour un abonnement permanent ; nous n'avons besoin que d'un
    instantané par relevé, donc on ne garde pas la connexion ouverte.
    """
    async with websockets.connect(WS_URL, subprotocols=[SUBPROTOCOL],
                                  additional_headers={"Origin": ORIGIN},
                                  open_timeout=timeout, max_size=None) as ws:
        await ws.send(json.dumps({"action": "identify",
                                  "data": {"uuid": "", "info": {"version": SUBPROTOCOL, "device": {}}}}))
        await ws.send(json.dumps({"action": "subscribe",
                                  "channel": {"name": channel, "params": params}}))

        deadline = time.time() + timeout
        while time.time() < deadline:
            raw = await asyncio.wait_for(ws.recv(), timeout=max(1.0, deadline - time.time()))
            if isinstance(raw, (bytes, bytearray)):
                raw = raw.decode("utf-8", "replace")
            message = json.loads(raw)
            # Les accusés de réception et l'annonce d'authentification passent d'abord.
            if message.get("type") == "response" or "auth" in message:
                continue
            if "data" in message:
                return message["data"]
    return None


def _query(channel: str, params: dict, timeout: float = 20):
    try:
        return asyncio.run(asyncio.wait_for(_query_async(channel, params, timeout), timeout + 5))
    except Exception:
        return None


# -------------------------------------------------------------------- lecture

def _reading(entry: dict, stamp: str | None) -> dict | None:
    """Un relevé kwind vers le format interne. Valeurs corrigées si présentes."""
    avg = entry.get("windspeedAdjusted", entry.get("sa"))
    if avg is None:
        avg = entry.get("windspeed", entry.get("s"))
    gust = entry.get("windspeedHighAdjusted", entry.get("sha"))
    if gust is None:
        gust = entry.get("windspeedHigh", entry.get("sh"))
    low = entry.get("windspeedLowAdjusted", entry.get("sla"))
    if low is None:
        low = entry.get("windspeedLow", entry.get("sl"))
    if avg is None and gust is None:
        return None

    direction = entry.get("direction", entry.get("d"))
    stamp = stamp or entry.get("timestamp")
    try:
        moment = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        moment = datetime.now(timezone.utc)

    return {
        "t": moment.astimezone(timezone.utc).replace(second=0, microsecond=0)
                   .isoformat().replace("+00:00", "Z"),
        "dir": int(direction) % 360 if direction is not None else None,
        "dirLabel": compass(direction),
        "avg": round(avg * KNOT_TO_KMH, 1) if avg is not None else None,
        "gust": round(gust * KNOT_TO_KMH, 1) if gust is not None else None,
        "gustDir": None,
        "min": round(low * KNOT_TO_KMH, 1) if low is not None else None,
        "temp": entry.get("temperature"),
        "lum": None,
        "stale": False,
    }


def _as_station(payload: dict) -> dict:
    return {
        "id": payload.get("_id"),
        "code": payload.get("_id"),
        "name": (payload.get("name") or "Station kwind").strip(),
        "lat": payload.get("latitude"),
        "lon": payload.get("longitude"),
        "altitude": payload.get("altitude"),
        "url": f"https://kwind.app/station/{payload.get('_id')}",
    }


def station(code: str) -> dict | None:
    data = _query("station", {"where": {"_id": code}})
    if not isinstance(data, dict) or not data.get("_id"):
        return None
    return _as_station(data)


def latest(code: str) -> dict | None:
    data = _query("station", {"where": {"_id": code}})
    if not isinstance(data, dict):
        return None
    wind = data.get("lastWindData")
    return _reading(wind, wind.get("timestamp")) if wind else None


def history(code: str, hours: int = 24) -> list[dict]:
    """Historique récent — appelé au premier suivi, puis on accumule."""
    start = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat().replace("+00:00", "Z")
    data = _query("winddata", {"where": {"stationId": code}, "startTimestamp": start,
                               "interval": 10, "granularity": 10}, timeout=30)
    entries = (data or {}).get("winddata") if isinstance(data, dict) else None
    if not entries:
        return []

    samples = []
    for entry in entries:
        sample = _reading(entry, entry.get("timestamp"))
        if not sample:
            continue
        for champ in ("stale", "lum", "dirLabel", "gustDir"):
            sample.pop(champ, None)
        samples.append(sample)
    samples.sort(key=lambda s: s["t"])
    return samples


# ------------------------------------------------------------------ catalogue

def stations(force: bool = False) -> list[dict]:
    if not force and _stations_cache["list"] and time.time() - _stations_cache["ts"] < STATIONS_TTL:
        return _stations_cache["list"]

    data = _query("stations", {"limit": 2000, "where": {"source": {"$ne": "airports"}}}, timeout=30)
    rows = data if isinstance(data, list) else (data or {}).get("data")
    if not rows:
        return _stations_cache["list"] or []

    found = {}
    for row in rows:
        if not isinstance(row, dict) or not row.get("_id"):
            continue
        info = _as_station(row)
        info.pop("url", None)
        found[info["id"]] = info
    result = sorted(found.values(), key=lambda s: s["name"])
    _stations_cache.update(list=result, ts=time.time())
    return result


def _offset(wind: dict) -> float | None:
    """Correction d'étalonnage choisie par le propriétaire, en nœuds (« +1.5 »)."""
    formula = wind.get("formula")
    if not formula:
        return None
    try:
        return float(str(formula).replace("+", "").strip())
    except ValueError:
        return None


def live_all_detailed() -> dict:
    """Relevé et empreinte de chaque station, en un seul appel.

    L'empreinte — mesure brute, température, pression — sert à repérer les
    fiches qui republient un même capteur physique. Autour de Tarifa, plusieurs
    balises partagent le même anémomètre et ne diffèrent que par leur correction.
    """
    data = _query("stations", {"limit": 2000, "where": {"source": {"$ne": "airports"}}}, timeout=30)
    rows = data if isinstance(data, list) else (data or {}).get("data") or []
    out = {}
    for row in rows:
        wind = row.get("lastWindData") if isinstance(row, dict) else None
        if not wind:
            continue
        reading = _reading(wind, wind.get("timestamp"))
        if not reading:
            continue
        out[str(row.get("_id"))] = {
            "reading": reading,
            "fingerprint": {
                "t": wind.get("timestamp"),
                "temp": wind.get("temperature"),
                "pressure": wind.get("pressure"),
                "raw_avg": wind.get("windspeed"),
                "raw_gust": wind.get("windspeedHigh"),
                "offset": _offset(wind),
            },
        }
    return out


def live_all() -> dict:
    """Dernier relevé de toutes les stations, en un seul appel."""
    return {code: entry["reading"] for code, entry in live_all_detailed().items()}


def search(query: str, limit: int = 40) -> list[dict]:
    import unicodedata

    def fold(text: str) -> str:
        return "".join(c for c in unicodedata.normalize("NFD", str(text).lower())
                       if unicodedata.category(c) != "Mn")

    needle = fold(query.strip())
    if not needle:
        return []
    hits = [s for s in stations() if needle in fold(s["name"])]
    hits.sort(key=lambda s: (not fold(s["name"]).startswith(needle), s["name"]))
    return hits[:limit]


if __name__ == "__main__":
    import sys
    code = sys.argv[1] if len(sys.argv) > 1 else "6a84ad4f865d8d8278583ca6"
    print("station   :", station(code))
    print("relevé    :", latest(code))
    h = history(code)
    print(f"historique: {len(h)} points", h[-1] if h else "")
    catalogue = stations()
    print("catalogue :", len(catalogue), "stations —", [s["name"] for s in catalogue[:3]])
    print("recherche 'tarifa' :", [s["name"] for s in search("tarifa")][:5])
