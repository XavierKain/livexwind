#!/usr/bin/env python3
"""Repère les appels réseau de windmorbihan.com pour trouver la source des relevés.

On charge la carte, on active la couche « Vent réel », puis on note toutes les
requêtes XHR/fetch — c'est là que se trouvent les données des balises.
"""

import re
from playwright.sync_api import sync_playwright

SKIP = re.compile(r"(\.js|\.css|\.png|\.jpg|\.jpeg|\.svg|\.woff|matomo|analytics|\.ico|\.webmanifest)", re.I)

seen = []

with sync_playwright() as pw:
    browser = pw.chromium.launch(headless=True)
    page = browser.new_page(locale="fr-FR", viewport={"width": 1400, "height": 1000})

    def note(resp):
        url = resp.url
        if SKIP.search(url):
            return
        entry = (resp.status, resp.headers.get("content-type", "")[:28], url)
        if entry not in seen:
            seen.append(entry)

    page.on("response", note)
    page.goto("https://www.windmorbihan.com", wait_until="domcontentloaded", timeout=90000)
    page.wait_for_timeout(9000)

    for label in ("Vent réel", "Vent reel", "Vent"):
        try:
            target = page.get_by_text(label, exact=True)
            if target.count():
                target.first.click(timeout=5000)
                print(f"→ clic sur « {label} »")
                page.wait_for_timeout(9000)
                break
        except Exception as exc:
            print(f"  (clic {label} impossible : {type(exc).__name__})")

    page.wait_for_timeout(4000)

    print(f"\n=== {len(seen)} requêtes")
    for status, ctype, url in seen:
        print(f"  {status} {ctype:30} {url[:160]}")

    page.screenshot(path="/tmp/wm.png", full_page=False)
    print("\ncapture: /tmp/wm.png")
    browser.close()
