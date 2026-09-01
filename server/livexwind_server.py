#!/usr/bin/env python3
"""
LiveXWind — API d'enregistrement + pousseur APNs.

Un seul processus, deux fils :
  • une API Flask (port 7110) où l'app iOS enregistre ses tokens push, ses seuils
    et la liste des balises qu'elle suit ;
  • une boucle qui relève ces balises et, dès qu'un nouveau relevé tombe sur la
    balise sélectionnée, pousse
    - une mise à jour de l'activité en direct (APNs push-type "liveactivity"),
    - un push-to-start si l'activité est morte (iOS la coupe au bout de 8 h),
    - une notification d'alerte si un seuil vient d'être franchi.

Toutes les balises suivies sont relevées, pour que changer de spot dans l'app
affiche une courbe déjà remplie ; seule la balise sélectionnée déclenche des push.

Le téléphone joint ce serveur via Tailscale (http://100.117.213.59:7110).

Config : ~/xklip/config/livexwind.json
  {
    "team_id":       "…",
    "apns_key_id":   "…",
    "apns_key_path": "/home/xavier/xklip/secrets/apns_key.p8",
    "bundle_id":     "com.xavierkain.livexwind"
  }

Dépendances : flask, httpx[http2], cryptography. Le JWT ES256 exigé par APNs est
signé directement avec cryptography, ce qui évite une dépendance de plus.
"""

from __future__ import annotations

import base64
import json
import logging
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, utils as asym_utils
from flask import Flask, jsonify, request

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "feed"))
import scrape  # noqa: E402  (source FFVL / balisemeteo.com)
import windmorbihan  # noqa: E402  (source windmorbihan.com)
import windguru  # noqa: E402  (source windguru.cz, mondiale)
from cadence import observed_period  # noqa: E402

PORT = 7110
HOME = Path.home()
CONFIG_PATH = HOME / "xklip" / "config" / "livexwind.json"
DATA_DIR = HOME / "xklip" / "data"
TOKENS_PATH = DATA_DIR / "livexwind_tokens.json"
STATE_PATH = DATA_DIR / "livexwind_state.json"

APNS_HOST = "https://api.push.apple.com"   # production : l'environnement des builds TestFlight
JWT_TTL = 40 * 60
DEFAULT_BALISE = {"id": 64, "name": "Pyla Pilat", "altitude": 55, "provider": "ffvl"}
PROVIDERS = ("ffvl", "wm", "wg")
BACKFILL_MIN_POINTS = 20
POLL_INTERVAL = 30              # repli quand la cadence d'une balise est inconnue
MAX_PERIOD = 900
CATCH_UP = 8                    # marge après l'heure attendue du prochain relevé
# Guet rapide sur la balise affichée quand la source est une API JSON bon marché.
# balisemeteo demande deux requêtes HTML par lecture et publie de toute façon
# toutes les 10 min : là, on programme le réveil au lieu de guetter.
FAST_WATCH = {"wm": 25, "wg": 25}
ALERT_INTERVAL = 120            # balise non affichée mais sous surveillance d'alerte
SECONDARY_INTERVAL = 5 * 60     # les autres balises suivies, moins souvent
ACTIVITY_MAX_AGE = 7.5 * 3600   # iOS coupe l'activité à 8 h → on la relance avant
START_COOLDOWN = 3600
PAGES_CLONE = DATA_DIR / "livexwind-pages"
PAGES_REMOTE = "https://github.com/XavierKain/livexwind.git"
PAGES_INTERVAL = 20 * 60        # on regroupe deux relevés par commit
# Miroir HTTPS public servi par nginx : c'est par là que passe l'Apple Watch,
# qui n'est pas sur Tailscale, et l'iPhone quand le VPN est coupé. Écriture de
# fichiers locaux, donc rien n'empêche de le rafraîchir à chaque relevé.
PUBLIC_DIR = Path("/var/www/livexwind")

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s [%(levelname)s] %(message)s",
                    datefmt="%Y-%m-%d %H:%M:%S")
log = logging.getLogger("livexwind")

app = Flask(__name__)
_lock = threading.Lock()
_jwt_cache = {"token": None, "ts": 0.0}


# --------------------------------------------------------------------------- io

def load_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def save_json(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    tmp.replace(path)


def feed_path(balise_id: int, provider: str = "ffvl") -> Path:
    return DATA_DIR / f"livexwind_feed_{provider}_{balise_id}.json"


def balise_key(balise: dict) -> str:
    return f"{balise.get('provider', 'ffvl')}-{balise['id']}"


def config() -> dict | None:
    cfg = load_json(CONFIG_PATH, None)
    if not cfg:
        return None
    if any(not cfg.get(k) for k in ("team_id", "apns_key_id", "apns_key_path", "bundle_id")):
        return None
    return cfg


# ------------------------------------------------------------------------- apns

def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def apns_jwt(cfg: dict) -> str:
    """JWT ES256 pour APNs — signature au format brut R||S, pas DER."""
    now = time.time()
    if _jwt_cache["token"] and now - _jwt_cache["ts"] < JWT_TTL:
        return _jwt_cache["token"]

    key = serialization.load_pem_private_key(Path(cfg["apns_key_path"]).read_bytes(), password=None)
    header = _b64(json.dumps({"alg": "ES256", "kid": cfg["apns_key_id"]}, separators=(",", ":")).encode())
    payload = _b64(json.dumps({"iss": cfg["team_id"], "iat": int(now)}, separators=(",", ":")).encode())
    signing_input = f"{header}.{payload}".encode()

    der = key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
    r, s = asym_utils.decode_dss_signature(der)
    raw = r.to_bytes(32, "big") + s.to_bytes(32, "big")

    token = f"{header}.{payload}.{_b64(raw)}"
    _jwt_cache.update(token=token, ts=now)
    return token


def apns_post(cfg: dict, token: str, payload: dict, push_type: str,
              topic_suffix: str = "", priority: str = "10") -> tuple[int, str]:
    headers = {
        "authorization": f"bearer {apns_jwt(cfg)}",
        "apns-topic": cfg["bundle_id"] + topic_suffix,
        "apns-push-type": push_type,
        "apns-priority": priority,
        "apns-expiration": str(int(time.time()) + 600),
    }
    with httpx.Client(http2=True, timeout=20) as client:
        resp = client.post(f"{APNS_HOST}/3/device/{token}", json=payload, headers=headers)
    return resp.status_code, resp.text


# --------------------------------------------------------------------- payloads

def iso_to_epoch(iso: str | None) -> float:
    if not iso:
        return time.time()
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return time.time()


def content_state(reading: dict, trend: list, unit: str) -> dict:
    """Doit correspondre exactement à WindActivityAttributes.ContentState côté Swift."""
    return {
        "averageKmh": reading.get("avg") or 0.0,
        "gustKmh": reading.get("gust") or 0.0,
        "minKmh": reading.get("min") or 0.0,
        "directionDegrees": reading.get("dir") or 0,
        "directionLabel": reading.get("dirLabel") or "—",
        "temperature": reading.get("temp"),
        "readingEpoch": iso_to_epoch(reading.get("t")),
        "trendKmh": trend or [reading.get("avg") or 0.0],
        "unitRaw": unit,
    }


def update_payload(state: dict, stale_epoch: float) -> dict:
    return {"aps": {"timestamp": int(time.time()),
                    "event": "update",
                    "content-state": state,
                    "stale-date": int(stale_epoch),
                    "relevance-score": 100}}


def start_payload(state: dict, balise_name: str, balise_id: int, stale_epoch: float) -> dict:
    # Pas de bloc "alert" : l'activité doit apparaître sans bannière de notification.
    return {"aps": {"timestamp": int(time.time()),
                    "event": "start",
                    "attributes-type": "WindActivityAttributes",
                    "attributes": {"baliseName": balise_name, "baliseID": balise_id},
                    "content-state": state,
                    "stale-date": int(stale_epoch),
                    "relevance-score": 100}}


def alert_payload(title: str, body: str) -> dict:
    return {"aps": {"alert": {"title": title, "body": body},
                    "sound": "default",
                    "interruption-level": "time-sensitive"}}


# ------------------------------------------------------------------------ store

def tokens() -> dict:
    return load_json(TOKENS_PATH, {"update": [], "start": [], "device": [], "prefs": {}})


def put_token(kind: str, value: str):
    with _lock:
        data = tokens()
        bucket = data.setdefault(kind, [])
        if value not in bucket:
            bucket.append(value)
            data[kind] = bucket[-5:]   # un token change à chaque nouvelle activité
        save_json(TOKENS_PATH, data)


def drop_token(kind: str, value: str):
    with _lock:
        data = tokens()
        data[kind] = [t for t in data.get(kind, []) if t != value]
        save_json(TOKENS_PATH, data)


def set_prefs(prefs: dict):
    with _lock:
        data = tokens()
        data.setdefault("prefs", {}).update({k: v for k, v in prefs.items() if v is not None})
        save_json(TOKENS_PATH, data)


def tracked_balises() -> tuple[list, int]:
    """Balises suivies, et identifiant de celle qui déclenche les push."""
    prefs = tokens().get("prefs", {})
    balises = prefs.get("balises") or [DEFAULT_BALISE]
    for b in balises:
        if b.get("provider") not in PROVIDERS:
            b["provider"] = "ffvl"
    ids = {b["id"] for b in balises}
    selected = prefs.get("selected")
    if selected not in ids:
        selected = balises[0]["id"]
    return balises, selected


# -------------------------------------------------------------------------- api

@app.route("/api/health")
def health():
    state = load_json(STATE_PATH, {})
    data = tokens()
    balises, selected = tracked_balises()
    return jsonify({"ok": True,
                    "apns_configured": bool(config()),
                    "tokens": {k: len(v) for k, v in data.items() if isinstance(v, list)},
                    "balises": [b["id"] for b in balises],
                    "selected": selected,
                    "last_reading": state.get("last_reading"),
                    "last_push": state.get("last_push"),
                    "windguru_index": windguru.index_progress()})


@app.route("/api/wind")
def wind():
    tracked, selected = tracked_balises()
    try:
        balise_id = int(request.args.get("balise", selected))
    except (TypeError, ValueError):
        balise_id = selected
    provider = request.args.get("provider")
    if provider not in PROVIDERS:
        match = next((b for b in tracked if b["id"] == balise_id), None)
        provider = (match or {}).get("provider", "ffvl")
    return jsonify(load_json(feed_path(balise_id, provider), {"error": "pas encore de relevé"}))


@app.route("/api/sensors")
def sensors():
    """Capteurs d'une source, pour le sélecteur de l'app.

    windmorbihan publie une liste complète ; windguru compte des milliers de
    stations et n'ouvre pas sa recherche, alors on interroge notre propre index.
    """
    provider = request.args.get("provider", "wm")
    query = (request.args.get("q") or "").strip()

    if provider == "wg":
        lat, lon = request.args.get("lat"), request.args.get("lon")
        if lat and lon:
            try:
                hits = windguru.nearby(float(lat), float(lon),
                                       radius_km=float(request.args.get("radius", 60)))
            except (TypeError, ValueError):
                hits = []
        else:
            hits = windguru.search(query) if query else []
        return jsonify({"provider": "wg", "sensors": hits,
                        "index": windguru.index_progress()})

    if provider != "wm":
        return jsonify({"error": "source inconnue"}), 400
    try:
        return jsonify({"provider": "wm", "sensors": windmorbihan.sensors()})
    except Exception as exc:
        log.warning("liste des capteurs windmorbihan indisponible : %s", exc)
        return jsonify({"provider": "wm", "sensors": []}), 502


@app.route("/api/balises", methods=["GET", "POST"])
def balises():
    if request.method == "GET":
        tracked, selected = tracked_balises()
        return jsonify({"balises": tracked, "selected": selected})

    body = request.get_json(silent=True) or {}
    cleaned = []
    for b in body.get("balises") or []:
        try:
            balise_id = int(b["id"])
        except (KeyError, TypeError, ValueError):
            continue
        provider = b.get("provider")
        cleaned.append({"id": balise_id,
                        "name": b.get("name") or f"Balise {balise_id}",
                        "altitude": b.get("altitude"),
                        "provider": provider if provider in PROVIDERS else "ffvl"})
    if not cleaned:
        return jsonify({"error": "liste vide ou invalide"}), 400

    set_prefs({"balises": cleaned, "selected": body.get("selected") or cleaned[0]["id"]})
    log.info("balises suivies : %s (sélectionnée %s)",
             [b["id"] for b in cleaned], body.get("selected"))
    return jsonify({"ok": True})


@app.route("/api/live-activity/register", methods=["POST"])
def la_register():
    body = request.get_json(silent=True) or {}
    token = (body.get("token") or "").strip()
    kind = body.get("kind", "update")
    if not token or kind not in ("update", "start"):
        return jsonify({"error": "token ou kind invalide"}), 400
    put_token(kind, token)
    set_prefs({"unit": body.get("unit")})
    log.info("token %s enregistré (%s…)", kind, token[:8])
    return jsonify({"ok": True})


@app.route("/api/live-activity/stop", methods=["POST"])
def la_stop():
    with _lock:
        data = tokens()
        data["update"] = []
        save_json(TOKENS_PATH, data)
    log.info("activité arrêtée côté app — tokens update purgés")
    return jsonify({"ok": True})


@app.route("/api/device/register", methods=["POST"])
def device_register():
    body = request.get_json(silent=True) or {}
    token = (body.get("token") or "").strip()
    if not token:
        return jsonify({"error": "token manquant"}), 400
    put_token("device", token)
    log.info("token appareil enregistré (%s…)", token[:8])
    return jsonify({"ok": True})


@app.route("/api/alerts", methods=["POST"])
def alerts():
    """Seuils d'une balise. Les conditions n'étant pas les mêmes d'un spot à
    l'autre, chaque balise a son propre jeu de réglages."""
    body = request.get_json(silent=True) or {}
    key = body.get("balise")
    if not key:
        return jsonify({"error": "balise manquante"}), 400

    with _lock:
        data = tokens()
        prefs = data.setdefault("prefs", {})
        by_balise = prefs.setdefault("alerts_by_balise", {})
        by_balise[key] = body.get("alerts") or {}
        if body.get("unit"):
            prefs["unit"] = body["unit"]
        prefs.pop("alerts", None)   # ancien réglage global
        save_json(TOKENS_PATH, data)

    log.info("seuils de %s : %s", key, body.get("alerts"))
    return jsonify({"ok": True})


@app.route("/")
def index():
    return jsonify({"service": "livexwind", "port": PORT,
                    "endpoints": ["/api/health", "/api/wind?balise=<id>", "/api/balises",
                                  "/api/live-activity/register", "/api/live-activity/stop",
                                  "/api/device/register", "/api/alerts"]})


# ----------------------------------------------------------------------- pusher

def refresh_feed(balise: dict) -> dict | None:
    """Relève une balise et met son flux à jour, quelle que soit sa source."""
    provider = balise.get("provider", "ffvl")
    if provider == "wm":
        return _refresh_wm(balise)
    if provider == "wg":
        return _refresh_wg(balise)
    return _refresh_ffvl(balise)


def _refresh_ffvl(balise: dict) -> dict | None:
    """balisemeteo.com : scraping, avec une seconde chance si la page est masquée."""
    balise_id = balise["id"]
    path = feed_path(balise_id, "ffvl")
    parsed = None
    for _ in range(2):
        try:
            parsed = scrape.parse(scrape.fetch(balise_id), balise_id)
        except Exception as exc:
            log.warning("balise %s : scraping impossible (%s)", balise_id, exc)
            return None
        if not parsed["reading"]["stale"]:
            break
        log.info("balise %s : page masquée par le site — nouvel essai", balise_id)
        time.sleep(4)

    if parsed["reading"]["stale"]:
        return load_json(path, None)

    return _store_feed(path, parsed["balise"], parsed["reading"])


def _refresh_wm(balise: dict) -> dict | None:
    """windmorbihan.com : API JSON, plus d'historique au premier suivi."""
    balise_id = balise["id"]
    path = feed_path(balise_id, "wm")
    try:
        reading = windmorbihan.latest(balise_id)
        info = windmorbihan.balise_info(balise_id)
    except Exception as exc:
        log.warning("balise wm %s : relevé indisponible (%s)", balise_id, exc)
        return None

    if not reading or not info:
        return load_json(path, None)

    old = load_json(path, {})
    if len(old.get("history", [])) < BACKFILL_MIN_POINTS:
        backfill = windmorbihan.history(balise_id)
        if backfill:
            log.info("balise wm %s : historique initial (%d points)", balise_id, len(backfill))
            old = {"history": backfill}

    return _store_feed(path, info, reading, previous=old)


def _refresh_wg(balise: dict) -> dict | None:
    """windguru.cz : API JSON ouverte, plus l'historique au premier suivi."""
    balise_id = balise["id"]
    path = feed_path(balise_id, "wg")
    reading = windguru.latest(balise_id)
    info = windguru.station(balise_id)
    if not reading or not info:
        return load_json(path, None)

    old = load_json(path, {})
    if len(old.get("history", [])) < BACKFILL_MIN_POINTS:
        backfill = windguru.history(balise_id)
        if backfill:
            log.info("balise wg %s : historique initial (%d points)", balise_id, len(backfill))
            old = {"history": backfill}

    return _store_feed(path, info, reading, previous=old)


def _store_feed(path: Path, info: dict, reading: dict, previous: dict | None = None) -> dict:
    old = previous if previous is not None else load_json(path, {})
    history = scrape.merge_history(old.get("history", []), reading)
    payload = {"generatedAt": datetime.now(timezone.utc).replace(microsecond=0)
                              .isoformat().replace("+00:00", "Z"),
               "balise": info,
               "current": reading,
               "period": observed_period(history),
               "history": history}
    save_json(path, payload)
    return payload


def alerts_for(key: str, prefs: dict) -> dict:
    return (prefs.get("alerts_by_balise") or {}).get(key) or {}


def evaluate_alert(reading: dict, settings: dict, unit: str, state: dict):
    """Même logique que AlertEngine côté Swift : on ne notifie qu'au franchissement."""
    if not settings.get("enabled"):
        return None, state

    value = reading.get("gust") if settings.get("useGusts") else reading.get("avg")
    if value is None:
        return None, state

    factor = 1.0 if unit == "kmh" else 1 / 1.852
    symbol = "km/h" if unit == "kmh" else "nds"

    upper = settings.get("upperKmh", 25)
    lower = settings.get("lowerKmh", 10)

    # On compare la valeur telle qu'elle est affichée dans l'app : 24,0 km/h se lit
    # « 13 nds » et doit franchir un seuil réglé sur 13 nds (24,076 km/h en interne).
    shown_value = round(value * factor)
    is_above = bool(settings.get("upperEnabled")) and shown_value >= round(upper * factor)
    is_below = bool(settings.get("lowerEnabled")) and shown_value <= round(lower * factor)

    # Secteur de direction : on prévient quand le vent bascule dans la fenêtre attendue.
    center = settings.get("directionCenter", 270)
    spread = settings.get("directionSpread", 45)
    bearing = reading.get("dir")
    in_sector = False
    if settings.get("directionEnabled") and bearing is not None:
        delta = abs(int(bearing) - int(center)) % 360
        in_sector = min(delta, 360 - delta) <= spread

    was_above = state.get("was_above", False)
    was_below = state.get("was_below", False)
    was_in_sector = state.get("was_in_sector", False)
    state["was_above"], state["was_below"] = is_above, is_below
    state["was_in_sector"] = in_sector

    hour = datetime.now().astimezone().hour
    start, end = settings.get("startHour", 8), settings.get("endHour", 21)
    in_window = (start <= hour < end) if start <= end else (hour >= start or hour < end)
    if not in_window:
        return None, state

    cooldown = settings.get("cooldownMinutes", 45) * 60
    source = "Rafales" if settings.get("useGusts") else "Vent moyen"
    shown = f"{shown_value} {symbol}"
    direction = f"{reading.get('dirLabel') or '—'} {reading.get('dir') or 0}°"

    def ready(key):
        last = state.get(key)
        return last is None or (time.time() - last) >= cooldown

    if is_above and not was_above and ready("last_upper"):
        state["last_upper"] = time.time()
        return {"title": f"Ça monte 🪁 {shown}",
                "body": f"{source} au-dessus de {round(upper * factor)} {symbol} · {direction}"}, state

    if is_below and not was_below and ready("last_lower"):
        state["last_lower"] = time.time()
        return {"title": f"Ça tombe 🍃 {shown}",
                "body": f"{source} sous {round(lower * factor)} {symbol} · {direction}"}, state

    if in_sector and not was_in_sector and ready("last_direction"):
        state["last_direction"] = time.time()
        low = (int(center) - int(spread)) % 360
        high = (int(center) + int(spread)) % 360
        return {"title": f"Le vent a tourné 🧭 {direction}",
                "body": f"Dans ton secteur {low}°–{high}° · {shown}"}, state

    return None, state


def push_all(cfg: dict, feed: dict, balise: dict, state: dict) -> dict:
    data = tokens()
    prefs = data.get("prefs", {})
    unit = prefs.get("unit", "kmh")
    reading = feed["current"]
    trend = [s["avg"] for s in feed.get("history", [])[-18:] if s.get("avg") is not None]
    body_state = content_state(reading, trend, unit)
    stale = iso_to_epoch(reading.get("t")) + 25 * 60
    name = feed["balise"].get("name") or balise.get("name") or "Balise"

    # 1. mise à jour de l'activité en direct
    delivered = 0
    for token in list(data.get("update", [])):
        code, text = apns_post(cfg, token, update_payload(body_state, stale),
                               "liveactivity", ".push-type.liveactivity")
        if code == 200:
            delivered += 1
        else:
            log.warning("update %s… → %s %s", token[:8], code, text[:160])
            if code in (400, 410):
                drop_token("update", token)

    # 2. relance à distance quand plus aucune activité n'est vivante
    started_at = state.get("activity_started_at", 0)
    needs_start = delivered == 0 or (time.time() - started_at) > ACTIVITY_MAX_AGE
    if needs_start and (time.time() - state.get("last_start", 0)) > START_COOLDOWN:
        for token in data.get("start", []):
            code, text = apns_post(cfg, token,
                                   start_payload(body_state, name, balise["id"], stale),
                                   "liveactivity", ".push-type.liveactivity")
            log.info("push-to-start %s… → %s", token[:8], code)
            if code == 200:
                state["last_start"] = time.time()
                state["activity_started_at"] = time.time()
            else:
                log.warning("push-to-start refusé : %s", text[:160])
                if code in (400, 410):
                    drop_token("start", token)
    elif delivered and not state.get("activity_started_at"):
        state["activity_started_at"] = time.time()

    state["last_push"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    state["pushed_reading"] = reading.get("t")
    return state


def push_alerts(cfg: dict, feed: dict, balise: dict, state: dict) -> dict:
    """Alertes de seuil d'une balise — évaluées même quand elle n'est pas affichée."""
    data = tokens()
    prefs = data.get("prefs", {})
    key = balise_key(balise)
    settings = alerts_for(key, prefs)
    if not settings.get("enabled"):
        return state

    reading = feed["current"]
    name = feed["balise"].get("name") or balise.get("name") or "Balise"
    latches = state.setdefault("alerts", {}).setdefault(key, {})

    # On ne réévalue pas deux fois le même relevé.
    if latches.get("reading") == reading.get("t"):
        return state
    latches["reading"] = reading.get("t")

    event, latches = evaluate_alert(reading, settings, prefs.get("unit", "kmh"), latches)
    state["alerts"][key] = latches
    if not event:
        return state

    for token in data.get("device", []):
        code, text = apns_post(cfg, token,
                               alert_payload(f"{name} · {event['title']}", event["body"]),
                               "alert")
        log.info("alerte %s (%s…) → %s : %s", name, token[:8], code, event["title"])
        if code in (400, 410):
            drop_token("device", token)
        elif code != 200:
            log.warning("alerte refusée : %s", text[:160])
    return state


def publish_public(feeds: dict):
    """Écrit les flux dans la racine nginx — immédiat, sans commit."""
    try:
        write_feed_files(PUBLIC_DIR, feeds)
    except OSError as exc:
        log.warning("miroir public indisponible : %s", exc)


def write_feed_files(docs: Path, feeds: dict):
    docs.mkdir(parents=True, exist_ok=True)
    for key, feed in feeds.items():
        (docs / f"balise-{key}.json").write_text(
            json.dumps(feed, ensure_ascii=False, indent=1) + "\n")
    (docs / "balises.json").write_text(
        json.dumps({"balises": [f["balise"] for f in feeds.values()]},
                   ensure_ascii=False, indent=1) + "\n")

    # Pointeur vers la balise affichée : c'est ainsi que l'Apple Watch sait quel
    # spot montrer, sans avoir à dialoguer avec l'iPhone.
    balises, selected = tracked_balises()
    chosen = next((b for b in balises if b["id"] == selected), None)
    if chosen:
        (docs / "selected.json").write_text(json.dumps({
            "key": balise_key(chosen),
            "id": chosen["id"],
            "name": chosen.get("name"),
            "provider": chosen.get("provider", "ffvl"),
        }, ensure_ascii=False, indent=1) + "\n")


def publish_to_pages(feeds: dict, state: dict) -> dict:
    """Publie les flux sur GitHub Pages, pour l'app quand elle est hors Tailscale.

    On passe par un clone dédié : le dépôt de travail ne doit pas être touché.
    """
    if time.time() - state.get("last_pages_push", 0) < PAGES_INTERVAL:
        return state

    try:
        if not (PAGES_CLONE / ".git").exists():
            subprocess.run(["git", "clone", "--depth", "1", PAGES_REMOTE, str(PAGES_CLONE)],
                           check=True, capture_output=True, timeout=120)

        docs = PAGES_CLONE / "docs"

        git = ["git", "-C", str(PAGES_CLONE), "-c", "credential.helper=store"]

        # On se recale sur l'amont avant d'écrire : ce clone est jetable, donc un
        # reset dur est sans risque et ne peut pas rester coincé dans un rebase
        # (contrairement à `pull --rebase`, qui s'était bloqué une fois).
        subprocess.run(git + ["rebase", "--abort"], capture_output=True, timeout=30)
        subprocess.run(git + ["fetch", "origin", "main"], check=True, capture_output=True, timeout=90)
        subprocess.run(git + ["reset", "--hard", "origin/main"], check=True, capture_output=True, timeout=30)

        write_feed_files(docs, feeds)

        subprocess.run(git + ["add", "docs"], check=True, capture_output=True, timeout=30)
        if subprocess.run(git + ["diff", "--cached", "--quiet"],
                          capture_output=True, timeout=30).returncode == 0:
            state["last_pages_push"] = time.time()
            return state

        subprocess.run(git + ["-c", "user.name=livexwind-bot",
                              "-c", "user.email=bot@users.noreply.github.com",
                              "commit", "-m", "flux: relevés balises"],
                       check=True, capture_output=True, timeout=30)
        subprocess.run(git + ["push"], check=True, capture_output=True, timeout=90)
        log.info("flux publiés sur GitHub Pages (%d balise(s))", len(feeds))
        state["last_pages_push"] = time.time()
    except subprocess.CalledProcessError as exc:
        log.warning("publication Pages échouée : %s", (exc.stderr or b"")[:200])
    except Exception as exc:
        log.warning("publication Pages échouée : %s", exc)
    return state


def migrate_legacy_feed():
    """Le flux d'avant le multi-balises n'était pas suffixé par l'identifiant."""
    target = feed_path(DEFAULT_BALISE["id"], "ffvl")
    if target.exists():
        return
    for legacy in (DATA_DIR / f"livexwind_feed_{DEFAULT_BALISE['id']}.json",
                   DATA_DIR / "livexwind_feed.json"):
        if legacy.exists():
            legacy.rename(target)
            log.info("ancien flux migré vers %s", target.name)
            return


def pusher_loop():
    log.info("boucle pusher démarrée")
    while True:
        cfg = config()
        if not cfg:
            log.warning("config APNs absente (%s) — nouvel essai dans 5 min", CONFIG_PATH)
            time.sleep(300)
            continue

        state = load_json(STATE_PATH, {})
        balises, selected = tracked_balises()
        refreshed_at = state.setdefault("refreshed_at", {})
        feeds = {}
        sleep_for = POLL_INTERVAL

        prefs = tokens().get("prefs", {})
        watched = any(alerts_for(balise_key(b), prefs).get("enabled")
                      for b in balises if b["id"] != selected)

        for balise in balises:
            balise_id = balise["id"]
            key = balise_key(balise)
            is_selected = balise_id == selected
            has_alerts = bool(alerts_for(key, prefs).get("enabled"))

            # Cadence : la balise affichée est guettée de près, celles qui ont une
            # alerte armée le sont raisonnablement, les autres ne servent qu'à
            # garnir la courbe quand on change de spot.
            cached_feed = load_json(feed_path(balise_id, balise.get("provider", "ffvl")), None) or {}
            period = cached_feed.get("period") or 600
            # La balise affichée est guettée à sa propre cadence ; celles qui ont
            # une alerte armée un peu moins souvent ; les autres au ralenti.
            interval = max(period, ALERT_INTERVAL if has_alerts else SECONDARY_INTERVAL)
            if not is_selected and time.time() - refreshed_at.get(key, 0) < interval:
                if cached_feed:
                    feeds[key] = cached_feed
                continue

            feed = refresh_feed(balise)
            refreshed_at[key] = time.time()
            if not feed:
                continue
            feeds[key] = feed

            # Les alertes valent pour toutes les balises suivies…
            try:
                state = push_alerts(cfg, feed, balise, state)
            except Exception as exc:
                log.exception("échec des alertes sur %s : %s", key, exc)

            # …mais l'activité en direct ne suit que la balise affichée.
            if not is_selected:
                continue

            current_t = feed["current"].get("t")
            if current_t and current_t != state.get("pushed_reading"):
                log.info("balise %s : nouveau relevé %s — %s km/h",
                         balise_id, current_t, feed["current"].get("avg"))
                try:
                    state = push_all(cfg, feed, balise, state)
                except Exception as exc:
                    log.exception("échec du push : %s", exc)
                state["last_reading"] = current_t
                fast = FAST_WATCH.get(balise.get("provider"))
                if fast:
                    # Guet régulier : c'est ce qui permet aussi de *mesurer* une
                    # cadence plus rapide que celle qu'on croyait.
                    sleep_for = fast
                else:
                    # Réveil programmé juste après le relevé attendu.
                    period = feed.get("period") or 600
                    sleep_for = max(15, min(iso_to_epoch(current_t) + period + CATCH_UP - time.time(),
                                            MAX_PERIOD))

        # Une alerte armée sur un spot non affiché ne doit pas attendre 10 min.
        if watched:
            sleep_for = min(sleep_for, ALERT_INTERVAL)

        if feeds:
            publish_public(feeds)
            state = publish_to_pages(feeds, state)
        state["refreshed_at"] = refreshed_at
        save_json(STATE_PATH, state)
        time.sleep(sleep_for)


def windguru_index_loop():
    """Balaye lentement le catalogue windguru pour alimenter la recherche.

    Volontairement peu pressé : quelques dizaines de fiches par minute, reprise
    là où on s'était arrêté, et l'index sert dès le premier lot.
    """
    log.info("indexation windguru démarrée")
    while True:
        try:
            progress = windguru.index_progress()
            if progress["scanned"] >= progress["total"]:
                time.sleep(24 * 3600)
                continue
            windguru.index_step()
            progress = windguru.index_progress()
            if progress["scanned"] % 500 < 40:
                log.info("index windguru : %d stations sur %d identifiants balayés",
                         progress["indexed"], progress["scanned"])
        except Exception as exc:
            log.warning("indexation windguru : %s", exc)
            time.sleep(120)
        time.sleep(5)


def main():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    migrate_legacy_feed()
    threading.Thread(target=pusher_loop, daemon=True).start()
    threading.Thread(target=windguru_index_loop, daemon=True).start()
    log.info("API LiveXWind sur le port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False)


if __name__ == "__main__":
    main()
