#!/usr/bin/env python3
"""
Crée la fiche de l'app dans App Store Connect — la seule étape qu'Apple refuse
d'exposer en API (`POST /v1/apps` n'existe pas).

Le script pilote appstoreconnect.apple.com avec Playwright. Il a besoin de toi
deux fois : le mot de passe Apple, puis le code à 6 chiffres de la double
authentification. La session est ensuite conservée dans ~/.livexwind-asc-session
donc les lancements suivants (autres apps, autres projets) n'auront plus rien à
demander tant qu'elle est valide.

    python3 tools/create_asc_app.py
    python3 tools/create_asc_app.py --dry-run       # s'arrête avant de valider
    python3 tools/create_asc_app.py --headed        # visible (nécessite un écran)
    python3 tools/create_asc_app.py --name "AutreApp" --bundle com.x.autre --sku autre

Captures d'écran de chaque étape dans /tmp/asc-*.png pour comprendre un échec.
"""

from __future__ import annotations

import argparse
import getpass
import os
import sys
from pathlib import Path

from playwright.sync_api import TimeoutError as PWTimeout, sync_playwright

SESSION_DIR = Path.home() / ".livexwind-asc-session"
SIGNIN_FRAME = "idmsa.apple.com"
SHOT_DIR = Path("/tmp")


def shot(page, name: str):
    path = SHOT_DIR / f"asc-{name}.png"
    try:
        page.screenshot(path=str(path), full_page=True)
        print(f"    capture → {path}")
    except Exception:
        pass


def signin_frame(page):
    for frame in page.frames:
        if SIGNIN_FRAME in frame.url:
            return frame
    return None


def login(page, apple_id: str) -> None:
    print("→ ouverture d'App Store Connect")
    page.goto("https://appstoreconnect.apple.com", wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(5000)

    if "/login" not in page.url:
        print("→ session déjà valide, pas de connexion à refaire")
        return

    frame = signin_frame(page)
    if frame is None:
        shot(page, "no-frame")
        sys.exit("Impossible de trouver le formulaire de connexion Apple.")

    print("→ saisie de l'identifiant")
    frame.fill("#account_name_text_field", apple_id)
    frame.press("#account_name_text_field", "Enter")
    page.wait_for_timeout(3500)

    password = os.environ.get("APPLE_PASSWORD") or getpass.getpass("Mot de passe Apple : ")
    frame = signin_frame(page) or frame
    try:
        frame.wait_for_selector("#password_text_field", timeout=20000)
    except PWTimeout:
        shot(page, "no-password-field")
        sys.exit("Le champ mot de passe n'est pas apparu (identifiant refusé ?).")

    print("→ saisie du mot de passe")
    frame.fill("#password_text_field", password)
    frame.press("#password_text_field", "Enter")
    page.wait_for_timeout(6000)
    shot(page, "after-password")

    # Double authentification : Apple envoie le code sur les appareils de confiance.
    frame = signin_frame(page) or frame
    needs_code = False
    for sel in ("input[id^=char]", ".form-security-code-input", "#char0"):
        try:
            if frame.locator(sel).count():
                needs_code = True
                break
        except Exception:
            continue

    if needs_code:
        code = os.environ.get("APPLE_2FA_CODE") or input("Code à 6 chiffres reçu sur tes appareils : ").strip()
        print("→ saisie du code")
        try:
            inputs = frame.locator("input[id^=char]")
            if inputs.count() >= 6:
                for i, digit in enumerate(code[:6]):
                    inputs.nth(i).fill(digit)
            else:
                frame.fill(".form-security-code-input", code)
        except Exception as exc:
            shot(page, "2fa-failed")
            sys.exit(f"Saisie du code impossible : {exc}")
        page.wait_for_timeout(9000)
        shot(page, "after-2fa")

        # « Faire confiance à ce navigateur »
        for label in ("Faire confiance", "Trust", "Ne pas faire confiance", "Don't Trust"):
            try:
                button = frame.get_by_role("button", name=label)
                if button.count():
                    button.first.click()
                    page.wait_for_timeout(5000)
                    break
            except Exception:
                continue

    page.wait_for_timeout(4000)
    if "/login" in page.url:
        shot(page, "still-login")
        sys.exit("Toujours sur la page de connexion — connexion échouée.")
    print(f"→ connecté ({page.url})")


def create_app(page, name: str, bundle: str, sku: str, language: str, dry_run: bool) -> None:
    print("→ ouverture de la liste des apps")
    page.goto("https://appstoreconnect.apple.com/apps", wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(6000)
    shot(page, "apps")

    print("→ clic sur « + »")
    clicked = False
    for sel in ("button[aria-label='Ajouter']", "button[aria-label='Add']",
                ".menu-toggle", "button:has-text('+')", "[data-test-id='add-app']"):
        try:
            locator = page.locator(sel)
            if locator.count():
                locator.first.click()
                clicked = True
                break
        except Exception:
            continue
    if not clicked:
        shot(page, "no-plus")
        sys.exit("Bouton « + » introuvable — la page a changé, regarde /tmp/asc-apps.png.")

    page.wait_for_timeout(1500)
    for label in ("Nouvelle app", "New App"):
        try:
            item = page.get_by_text(label, exact=False)
            if item.count():
                item.first.click()
                break
        except Exception:
            continue

    page.wait_for_timeout(4000)
    shot(page, "new-app-dialog")

    print("→ remplissage du formulaire")
    try:
        page.get_by_role("checkbox", name="iOS").check(timeout=8000)
    except Exception:
        try:
            page.locator("input[type=checkbox][value=ios]").first.check()
        except Exception:
            print("    ! plateforme iOS non cochable automatiquement")

    for sel, value in (("input[name=name]", name), ("input[name=sku]", sku)):
        try:
            page.locator(sel).first.fill(value)
        except Exception:
            print(f"    ! champ {sel} introuvable")

    for sel, value in (("select[name=primaryLanguage]", language),
                       ("select[name=bundleId]", bundle)):
        try:
            page.locator(sel).first.select_option(label=value)
        except Exception:
            try:
                page.locator(sel).first.select_option(value=value)
            except Exception:
                print(f"    ! sélection {sel} = {value} impossible")

    shot(page, "form-filled")

    if dry_run:
        print("→ --dry-run : formulaire rempli, rien n'est validé.")
        return

    print("→ validation")
    for label in ("Créer", "Create"):
        try:
            button = page.get_by_role("button", name=label)
            if button.count():
                button.first.click()
                break
        except Exception:
            continue

    page.wait_for_timeout(9000)
    shot(page, "after-create")
    print("→ terminé — vérifie /tmp/asc-after-create.png et la liste des apps.")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", default="LiveXWind")
    ap.add_argument("--bundle", default="com.xavierkain.livexwind")
    ap.add_argument("--sku", default="livexwind")
    ap.add_argument("--language", default="Français")
    ap.add_argument("--apple-id", default=os.environ.get("APPLE_ID"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--headed", action="store_true")
    args = ap.parse_args()

    apple_id = args.apple_id or input("Apple ID (email) : ").strip()

    with sync_playwright() as pw:
        context = pw.chromium.launch_persistent_context(
            str(SESSION_DIR),
            headless=not args.headed,
            locale="fr-FR",
            viewport={"width": 1440, "height": 1000},
        )
        page = context.pages[0] if context.pages else context.new_page()
        try:
            login(page, apple_id)
            create_app(page, args.name, args.bundle, args.sku, args.language, args.dry_run)
        finally:
            context.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
