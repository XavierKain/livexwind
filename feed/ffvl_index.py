#!/usr/bin/env python3
"""
Catalogue des balises FFVL, construit par balayage.

balisemeteo.com n'expose pas de liste géolocalisée : les données ouvertes de la
FFVL demandent une clé (informatique@ffvl.fr), et `balise_nearby.php` ne renvoie
qu'une seule balise. On assemble donc l'index nous-mêmes :

  1. les pages département listent les identifiants de balises ;
  2. la fiche de chaque balise donne son nom et sa position.

Le balayage est lent et reprend là où il s'est arrêté, comme celui de windguru.
La session est amorcée une seule fois pour toute la passe, au lieu des deux
requêtes par lecture que fait `scrape.fetch`.
"""

from __future__ import annotations

import json
import re
import sys
import time
from datetime import datetime, timezone
from http.cookiejar import CookieJar
from pathlib import Path
from urllib.request import HTTPCookieProcessor, Request, build_opener

sys.path.insert(0, str(Path(__file__).resolve().parent))
import scrape  # noqa: E402

INDEX_PATH = Path.home() / "xklip" / "data" / "ffvl_index.json"
# Départements métropolitains + Corse + outre-mer, tels que numérotés par le site.
# Sur deux chiffres : le site ignore « dept=6 » mais répond à « dept=06 ».
DEPARTMENTS = [f"{d:02d}" for d in range(1, 96)] + ["2A", "2B", "971", "972", "973", "974", "976"]


def load_index() -> dict:
    try:
        return json.loads(INDEX_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"pending": None, "done_departments": [], "stations": {}, "updated": None}


def save_index(index: dict):
    INDEX_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = INDEX_PATH.with_suffix(".tmp")
    tmp.write_text(json.dumps(index, ensure_ascii=False))
    tmp.replace(INDEX_PATH)


def _opener():
    """Session amorcée : balisemeteo masque ses valeurs sans cookie."""
    opener = build_opener(HTTPCookieProcessor(CookieJar()))
    opener.open(Request("https://www.balisemeteo.com/index.php",
                        headers={"User-Agent": scrape.UA}), timeout=25).read()
    return opener


def _get(opener, url: str) -> str:
    return opener.open(Request(url, headers={"User-Agent": scrape.UA}),
                       timeout=25).read().decode("utf-8", "replace")


def index_step(batch: int = 25, pause: float = 1.0) -> dict:
    """Avance le balayage d'un lot. Appelé en boucle, lentement, en tâche de fond."""
    index = load_index()
    pending = index.get("pending")

    try:
        opener = _opener()
    except Exception:
        return index

    # Phase 1 : recenser les identifiants, département par département.
    if pending is None:
        remaining = [d for d in DEPARTMENTS if d not in index.get("done_departments", [])]
        if remaining:
            found = set()
            for dept in remaining[:batch]:
                try:
                    doc = _get(opener, f"https://www.balisemeteo.com/depart.php?dept={dept}")
                except Exception:
                    continue
                found.update(re.findall(r"idBalise=(\d+)", doc))
                index.setdefault("done_departments", []).append(dept)
                time.sleep(pause)

            known = set(index.get("stations", {}))
            queued = set(index.get("queue", []))
            index["queue"] = sorted(queued | (found - known))
            save_index(index)
            return index
        index["pending"] = "stations"
        save_index(index)

    # Phase 2 : lire la fiche de chaque balise pour son nom et sa position.
    queue = index.get("queue", [])
    for balise_id in queue[:batch]:
        try:
            doc = _get(opener, f"https://www.balisemeteo.com/balise.php?idBalise={balise_id}")
            info = scrape.parse(doc, int(balise_id))["balise"]
            if info.get("lat") is not None:
                index.setdefault("stations", {})[str(balise_id)] = {
                    "id": int(balise_id), "code": str(balise_id), "name": info["name"],
                    "lat": info["lat"], "lon": info["lon"], "altitude": info.get("altitude"),
                }
        except Exception:
            pass
        time.sleep(pause)

    index["queue"] = queue[batch:]
    index["updated"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    save_index(index)
    return index


def stations() -> list[dict]:
    return sorted(load_index().get("stations", {}).values(), key=lambda s: s["name"])


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


def progress() -> dict:
    index = load_index()
    return {"indexed": len(index.get("stations", {})),
            "queue": len(index.get("queue", [])),
            "departments": len(index.get("done_departments", [])),
            "total_departments": len(DEPARTMENTS),
            "updated": index.get("updated")}


if __name__ == "__main__":
    print("avant :", progress())
    index_step(batch=8, pause=0.5)
    print("après :", progress())
