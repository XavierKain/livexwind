#!/usr/bin/env python3
"""
Scrape balisemeteo.com (FFVL) et publie un JSON avec le relevé courant + l'historique.

balisemeteo.com masque les valeurs (!!! WARNING !!!) tant que le client n'a pas de
session PHP : on fait donc une requête d'amorçage pour récupérer le cookie PHPSESSID,
puis la vraie requête sur la fiche balise.

Usage :
    python3 feed/scrape.py --balise 64 --out docs/balise-64.json
"""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import URLError
from urllib.request import HTTPCookieProcessor, Request, build_opener
from http.cookiejar import CookieJar

BASE = "https://www.balisemeteo.com"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
HISTORY_HOURS = 48
# La France (métropole) est en UTC+2 d'avril à octobre, UTC+1 sinon. Le site affiche
# l'heure locale ; on convertit sans dépendance externe (zoneinfo absent sur certains runners).
PARIS_DST_MONTHS = range(4, 11)


def paris_offset(dt_naive: datetime) -> timedelta:
    return timedelta(hours=2 if dt_naive.month in PARIS_DST_MONTHS else 1)


def fetch(balise: int) -> str:
    jar = CookieJar()
    opener = build_opener(HTTPCookieProcessor(jar))
    headers = {"User-Agent": UA, "Accept-Language": "fr-FR,fr;q=0.9"}
    url = f"{BASE}/balise.php?idBalise={balise}"
    # 1) amorçage session, 2) vraie lecture
    for attempt in range(2):
        req = Request(url if attempt else f"{BASE}/index.php", headers=headers)
        with opener.open(req, timeout=25) as resp:
            body = resp.read().decode("utf-8", errors="replace")
    return body


def clean(fragment: str) -> str:
    return html.unescape(re.sub(r"<[^>]+>", "", fragment)).strip()


def field(doc: str, label: str, after: str | None = None) -> str | None:
    """Valeur de la ligne <td class="label">label :</td><td class="valeur">…</td>."""
    scope = doc
    if after:
        idx = doc.find(after)
        if idx == -1:
            return None
        scope = doc[idx:]
    m = re.search(
        r'<td class="label">\s*' + re.escape(label) + r'\s*:\s*</td>\s*<td class="valeur">(.*?)</td>',
        scope,
        re.S,
    )
    return clean(m.group(1)) if m else None


def speed(value: str | None) -> float | None:
    if not value:
        return None
    m = re.search(r"(-?\d+(?:[.,]\d+)?)\s*km/h", value)
    return float(m.group(1).replace(",", ".")) if m else None


def direction(value: str | None) -> tuple[int | None, str | None]:
    if not value:
        return None, None
    m = re.search(r"([A-ZÀ-Ÿ]{1,3})\s*:\s*(-?\d+)\s*°", value)
    if m:
        return int(m.group(2)) % 360, m.group(1)
    m = re.search(r"(-?\d+)\s*°", value)
    return (int(m.group(1)) % 360, None) if m else (None, None)


def number(value: str | None) -> float | None:
    if not value:
        return None
    m = re.search(r"(-?\d+(?:[.,]\d+)?)", value)
    return float(m.group(1).replace(",", ".")) if m else None


def parse(doc: str, balise: int) -> dict:
    m = re.search(r'<div class="Titre"\s*>Relev&eacute; du ([^<]+)</div>|<div class="Titre"\s*>Relevé du ([^<]+)</div>', doc)
    stamp = clean(m.group(1) or m.group(2)) if m else None
    reading_at = None
    if stamp:
        d = re.search(r"(\d{2})/(\d{2})/(\d{4})\s*-\s*(\d{2}):(\d{2})", stamp)
        if d:
            naive = datetime(int(d.group(3)), int(d.group(2)), int(d.group(1)), int(d.group(4)), int(d.group(5)))
            reading_at = (naive - paris_offset(naive)).replace(tzinfo=timezone.utc)

    name = None
    n = re.search(r"<title>.*?</title>.*?<p><b>([^<]+)</b></p>", doc, re.S)
    if n:
        name = clean(n.group(1))
    if not name:
        n = re.search(r"<h1>([^<]+)</h1>", doc)
        name = clean(n.group(1)) if n else f"Balise {balise}"

    lat = lon = None
    g = re.search(r"maps/preview\?q=(-?\d+\.\d+),(-?\d+\.\d+)", doc)
    if g:
        lat, lon = float(g.group(1)), float(g.group(2))
    alt = None
    a = re.search(r"Altitude\s*:\s*(\d+)\s*m", doc)
    if a:
        alt = int(a.group(1))

    avg_dir, avg_label = direction(field(doc, "Direction"))
    avg_speed = speed(field(doc, "Vitesse"))
    max_block = "Vent maxi"
    gust_dir, gust_label = direction(field(doc, "Direction", after=max_block))
    gust_speed = speed(field(doc, "Vitesse", after=max_block))
    min_speed = speed(field(doc, "Vitesse minimum"))
    temp = number(field(doc, "Température"))
    lum = number(field(doc, "Luminosité"))

    stale = "WARNING" in doc and avg_speed is None

    return {
        "balise": {
            "id": balise,
            "name": name,
            "lat": lat,
            "lon": lon,
            "altitude": alt,
            "url": f"{BASE}/balise.php?idBalise={balise}",
        },
        "reading": {
            "t": reading_at.isoformat().replace("+00:00", "Z") if reading_at else None,
            "dir": avg_dir,
            "dirLabel": avg_label,
            "avg": avg_speed,
            "gust": gust_speed,
            "gustDir": gust_dir,
            "gustDirLabel": gust_label,
            "min": min_speed,
            "temp": temp,
            "lum": lum,
            "stale": stale,
        },
    }


def merge_history(previous: list[dict], reading: dict) -> list[dict]:
    if not reading.get("t") or reading.get("avg") is None:
        return previous
    sample = {k: reading.get(k) for k in ("t", "dir", "avg", "gust", "min", "temp")}
    by_time = {s["t"]: s for s in previous if s.get("t")}
    by_time[sample["t"]] = sample
    cutoff = datetime.now(timezone.utc) - timedelta(hours=HISTORY_HOURS)
    out = []
    for s in by_time.values():
        try:
            when = datetime.fromisoformat(s["t"].replace("Z", "+00:00"))
        except ValueError:
            continue
        if when >= cutoff:
            out.append(s)
    out.sort(key=lambda s: s["t"])
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--balise", type=int, default=64)
    ap.add_argument("--out", default="docs/balise-64.json")
    args = ap.parse_args()

    try:
        doc = fetch(args.balise)
    except (URLError, TimeoutError) as exc:
        print(f"fetch failed: {exc}", file=sys.stderr)
        return 1

    parsed = parse(doc, args.balise)
    if parsed["reading"]["stale"]:
        print("relevé masqué par le site (WARNING) — historique conservé", file=sys.stderr)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    old = {}
    if out.exists():
        try:
            old = json.loads(out.read_text())
        except json.JSONDecodeError:
            old = {}

    history = merge_history(old.get("history", []), parsed["reading"])
    payload = {
        "generatedAt": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "balise": parsed["balise"],
        "current": parsed["reading"] if not parsed["reading"]["stale"] else (old.get("current") or parsed["reading"]),
        "history": history,
    }
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + "\n")
    cur = payload["current"]
    print(f"{cur['t']} — {cur['avg']} km/h moy / {cur['gust']} raf — {cur['dirLabel']} {cur['dir']}° — {len(history)} points")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
