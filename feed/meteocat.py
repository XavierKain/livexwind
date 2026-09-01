#!/usr/bin/env python3
"""
Source meteo.cat — réseau XEMA du Servei Meteorològic de Catalunya.

C'est ce qui couvre les spots catalans, dont Àger (station « Montsec d'Ares »,
code WQ). La page d'une station est rendue côté serveur : pas d'API à deviner,
un tableau HTML semi-horaire suffit.

    https://www.meteo.cat/observacions/xema/dades?codi=WQ

Colonnes utiles du tableau : VVM (vent moyen), DVM (direction moyenne),
VVX (rafale maximale). Les vitesses sont **déjà en km/h**, l'unité interne de
LiveXWind, et les heures sont en **TU** — donc en UTC, sans conversion.

Les stations sont identifiées par un code alphabétique, pas par un nombre :
c'est pour elles que `Balise` porte un `code` distinct de son identifiant.
"""

from __future__ import annotations

import html as html_lib
import re
from datetime import datetime, timedelta, timezone
from urllib.request import Request, urlopen

BASE = "https://www.meteo.cat/observacions/xema"
LIST_URL = "https://www.meteo.cat/observacions/llistat-xema"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

COMPASS = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
           "S", "SSO", "SO", "OSO", "O", "ONO", "NO", "NNO"]

_stations_cache: dict = {"list": None, "ts": None}


def compass(degrees) -> str | None:
    if degrees is None:
        return None
    return COMPASS[int(round(float(degrees) / 22.5)) % 16]


def _fetch(url: str, timeout: int = 30) -> str:
    req = Request(url, headers={"User-Agent": UA, "Accept-Language": "ca,fr;q=0.8"})
    with urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", errors="replace")


def _text(fragment: str) -> str:
    return html_lib.unescape(re.sub(r"<[^>]+>", " ", fragment)).strip()


def _number(value: str):
    value = value.replace(",", ".").strip()
    try:
        return float(value)
    except ValueError:
        return None


def _data_table(doc: str) -> tuple[list, list]:
    """Le tableau des relevés : celui dont l'en-tête contient « Període »."""
    for table in re.findall(r"<table.*?</table>", doc, re.S):
        headers = [_text(h) for h in re.findall(r"<th.*?</th>", table, re.S)]
        if any("Període" in h for h in headers):
            rows = []
            for row in re.findall(r"<tr.*?</tr>", table, re.S):
                cells = [_text(c) for c in re.findall(r"<t[dh].*?</t[dh]>", row, re.S)]
                if cells and re.match(r"^\d{2}:\d{2}", cells[0]):
                    rows.append(cells)
            return headers, rows
    return [], []


def _column_index(headers: list, prefix: str) -> int | None:
    for i, header in enumerate(headers):
        if header.replace(" ", "").upper().startswith(prefix):
            return i
    return None


def _page_date(doc: str) -> datetime:
    """Jour affiché par la page, en UTC (les heures du tableau sont en TU)."""
    match = re.search(r"\b(\d{2})\.(\d{2})\.(\d{4})\b", doc)
    if match:
        day, month, year = (int(g) for g in match.groups())
        return datetime(year, month, day, tzinfo=timezone.utc)
    now = datetime.now(timezone.utc)
    return datetime(now.year, now.month, now.day, tzinfo=timezone.utc)


def _samples(doc: str) -> list[dict]:
    headers, rows = _data_table(doc)
    if not rows:
        return []

    # L'en-tête décale d'une colonne : la première cellule est la période.
    idx_avg = _column_index(headers, "VVM")
    idx_dir = _column_index(headers, "DVM")
    idx_gust = _column_index(headers, "VVX")
    idx_temp = _column_index(headers, "TM")
    if idx_avg is None or idx_gust is None:
        return []

    day = _page_date(doc)
    samples = []
    for cells in rows:
        # « 18:30 - 19:00 » : on date le relevé à la fin de la période.
        end = re.search(r"-\s*(\d{2}):(\d{2})", cells[0])
        if not end:
            continue
        hour, minute = int(end.group(1)), int(end.group(2))
        stamp = day + timedelta(hours=hour, minutes=minute)
        if hour == 0 and minute == 0:
            stamp += timedelta(days=1)   # période 23:30 – 00:00

        def cell(i):
            return _number(cells[i]) if i is not None and i < len(cells) else None

        avg, gust = cell(idx_avg), cell(idx_gust)
        if avg is None and gust is None:
            continue
        direction = cell(idx_dir)
        samples.append({
            "t": stamp.isoformat().replace("+00:00", "Z"),
            "dir": int(direction) % 360 if direction is not None else None,
            "dirLabel": compass(direction),
            "avg": avg,
            "gust": gust,
            "gustDir": None,
            "min": None,
            "temp": cell(idx_temp),
            "lum": None,
            "stale": False,
        })
    return samples


def station(code: str) -> dict | None:
    """Fiche de la station, ou None si le code n'existe pas."""
    try:
        doc = _fetch(f"{BASE}/dades?codi={code}")
    except Exception:
        return None

    title = re.search(r"<title>([^<]+)</title>", doc)
    if not title:
        return None
    name = html_lib.unescape(title.group(1))
    name = re.sub(r"^Dades de l'estaci[óo] autom[àa]tica\s*", "", name)
    name = re.sub(r"\s*\|.*$", "", name).strip()
    if not name or "Meteocat" in name:
        return None

    altitude = re.search(r"Altitud.{0,80}?(\d[\d.\s]*)\s*m", doc, re.S)
    return {
        "id": code,
        "code": code,
        "name": re.sub(r"\s*\(.*?\)\s*$", "", name).strip(),
        "lat": None,
        "lon": None,
        "altitude": int(altitude.group(1).replace(".", "").replace(" ", "")) if altitude else None,
        "url": f"{BASE}/dades?codi={code}",
    }


def latest(code: str) -> dict | None:
    try:
        samples = _samples(_fetch(f"{BASE}/dades?codi={code}"))
    except Exception:
        return None
    return samples[-1] if samples else None


def history(code: str) -> list[dict]:
    """Relevés du jour — la page n'en publie pas davantage."""
    try:
        samples = _samples(_fetch(f"{BASE}/dades?codi={code}"))
    except Exception:
        return []
    for sample in samples:
        for champ in ("stale", "lum", "dirLabel", "gustDir"):
            sample.pop(champ, None)
    return samples


def stations() -> list[dict]:
    """Les ~190 stations XEMA, pour la recherche par nom."""
    if _stations_cache["list"]:
        return _stations_cache["list"]
    try:
        doc = _fetch(LIST_URL)
    except Exception:
        return []

    found = {}
    for code, label in re.findall(r'dades\?codi=([A-Z0-9]+)[^>]*>([^<]{2,80})</a>', doc):
        name = re.sub(r"\s*\[[A-Z0-9]+\]\s*$", "", html_lib.unescape(label)).strip()
        altitude = re.search(r"\((\d[\d.\s]*)\s*m\)\s*$", name)
        name = re.sub(r"\s*\(.*?\)\s*$", "", name).strip()
        if name:
            found[code] = {
                "id": code, "code": code, "name": name, "lat": None, "lon": None,
                "altitude": int(altitude.group(1).replace(".", "").replace(" ", "")) if altitude else None,
            }
    result = sorted(found.values(), key=lambda s: s["name"])
    _stations_cache["list"] = result
    return result


def search(query: str, limit: int = 40) -> list[dict]:
    import unicodedata

    def fold(text: str) -> str:
        return "".join(c for c in unicodedata.normalize("NFD", text.lower())
                       if unicodedata.category(c) != "Mn")

    needle = fold(query.strip())
    if not needle:
        return []
    hits = [s for s in stations() if needle in fold(s["name"]) or needle == s["code"].lower()]
    return hits[:limit]


if __name__ == "__main__":
    import sys
    code = sys.argv[1] if len(sys.argv) > 1 else "WQ"
    print("station  :", station(code))
    print("relevé   :", latest(code))
    h = history(code)
    print(f"historique: {len(h)} points", h[-1] if h else "")
    print("recherche 'ager' :", [s["name"] for s in search("ager")][:5])
    print("stations :", len(stations()))
