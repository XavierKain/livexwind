#!/usr/bin/env python3
"""Liste les requêtes de données d'une page — sert à trouver l'API d'une nouvelle source.

    python3 tools/probe_network.py <url> [secondes]
"""
import re
import sys
from playwright.sync_api import sync_playwright

STATIC = re.compile(r"\.(js|css|png|jpe?g|svg|webp|woff2?|ico|gif|mp4|webmanifest)(\?|$)", re.I)

url = sys.argv[1]
wait = int(sys.argv[2]) if len(sys.argv) > 2 else 12

seen = []
with sync_playwright() as pw:
    b = pw.chromium.launch(headless=True)
    page = b.new_page(locale="fr-FR", viewport={"width": 1400, "height": 1000})
    page.on("request", lambda r: seen.append((r.method, r.url)) if not STATIC.search(r.url) else None)
    page.goto(url, wait_until="domcontentloaded", timeout=90000)
    page.wait_for_timeout(wait * 1000)
    print(f"=== {len(seen)} requêtes non statiques")
    for m, u in dict.fromkeys(seen):
        print(f"  {m} {u[:190]}")
    b.close()
