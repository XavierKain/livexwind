#!/usr/bin/env python3
"""
LiveXWind — API d'enregistrement + pousseur APNs.

Un seul processus, deux fils :
  • une API Flask (port 7110) où l'app iOS enregistre ses tokens push et ses seuils ;
  • une boucle qui suit la balise et, dès qu'un nouveau relevé tombe, pousse
    - une mise à jour de l'activité en direct (APNs push-type "liveactivity"),
    - un push-to-start si l'activité est morte (iOS la coupe au bout de 8 h),
    - une notification d'alerte si un seuil vient d'être franchi.

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
import scrape  # noqa: E402  (le même scraper que GitHub Actions)

PORT = 7110
HOME = Path.home()
CONFIG_PATH = HOME / "xklip" / "config" / "livexwind.json"
DATA_DIR = HOME / "xklip" / "data"
TOKENS_PATH = DATA_DIR / "livexwind_tokens.json"
STATE_PATH = DATA_DIR / "livexwind_state.json"
FEED_PATH = DATA_DIR / "livexwind_feed.json"

APNS_HOST = "https://api.push.apple.com"   # production : l'environnement des builds TestFlight
JWT_TTL = 40 * 60
BALISE_ID = 64
POLL_INTERVAL = 30
ACTIVITY_MAX_AGE = 7.5 * 3600   # iOS coupe l'activité à 8 h → on la relance avant
START_COOLDOWN = 3600

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


def start_payload(state: dict, balise_name: str, stale_epoch: float) -> dict:
    return {"aps": {"timestamp": int(time.time()),
                    "event": "start",
                    "attributes-type": "WindActivityAttributes",
                    "attributes": {"baliseName": balise_name, "baliseID": BALISE_ID},
                    "content-state": state,
                    "stale-date": int(stale_epoch),
                    "relevance-score": 100,
                    "alert": {"title": "LiveXWind", "body": "Vent en direct"}}}


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


# -------------------------------------------------------------------------- api

@app.route("/api/health")
def health():
    state = load_json(STATE_PATH, {})
    data = tokens()
    return jsonify({"ok": True,
                    "apns_configured": bool(config()),
                    "tokens": {k: len(v) for k, v in data.items() if isinstance(v, list)},
                    "last_reading": state.get("last_reading"),
                    "last_push": state.get("last_push")})


@app.route("/api/wind")
def wind():
    return jsonify(load_json(FEED_PATH, {"error": "pas encore de relevé"}))


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
    body = request.get_json(silent=True) or {}
    set_prefs({"alerts": body.get("alerts"), "unit": body.get("unit")})
    log.info("seuils mis à jour : %s", body.get("alerts"))
    return jsonify({"ok": True})


@app.route("/")
def index():
    return jsonify({"service": "livexwind", "port": PORT,
                    "endpoints": ["/api/health", "/api/wind",
                                  "/api/live-activity/register", "/api/live-activity/stop",
                                  "/api/device/register", "/api/alerts"]})


# ----------------------------------------------------------------------- pusher

def refresh_feed() -> dict | None:
    """Rejoue le scraper partagé et renvoie le flux complet."""
    parsed = None
    for attempt in range(2):
        try:
            parsed = scrape.parse(scrape.fetch(BALISE_ID), BALISE_ID)
        except Exception as exc:
            log.warning("scraping impossible : %s", exc)
            return None
        if not parsed["reading"]["stale"]:
            break
        log.info("page masquée par le site — nouvel essai")
        time.sleep(4)

    if parsed["reading"]["stale"]:
        return load_json(FEED_PATH, None)

    old = load_json(FEED_PATH, {})
    payload = {"generatedAt": datetime.now(timezone.utc).replace(microsecond=0)
                              .isoformat().replace("+00:00", "Z"),
               "balise": parsed["balise"],
               "current": parsed["reading"],
               "history": scrape.merge_history(old.get("history", []), parsed["reading"])}
    save_json(FEED_PATH, payload)
    return payload


def evaluate_alert(reading: dict, prefs: dict, state: dict):
    """Même logique que AlertEngine côté Swift : on ne notifie qu'au franchissement."""
    settings = (prefs or {}).get("alerts") or {}
    if not settings.get("enabled"):
        return None, state

    value = reading.get("gust") if settings.get("useGusts") else reading.get("avg")
    if value is None:
        return None, state

    unit = prefs.get("unit", "kmh")
    factor = 1.0 if unit == "kmh" else 1 / 1.852
    symbol = "km/h" if unit == "kmh" else "nds"

    upper = settings.get("upperKmh", 25)
    lower = settings.get("lowerKmh", 10)
    is_above = bool(settings.get("upperEnabled")) and value >= upper
    is_below = bool(settings.get("lowerEnabled")) and value <= lower
    was_above, was_below = state.get("was_above", False), state.get("was_below", False)
    state["was_above"], state["was_below"] = is_above, is_below

    hour = datetime.now().astimezone().hour
    start, end = settings.get("startHour", 8), settings.get("endHour", 21)
    in_window = (start <= hour < end) if start <= end else (hour >= start or hour < end)
    if not in_window:
        return None, state

    cooldown = settings.get("cooldownMinutes", 45) * 60
    source = "Rafales" if settings.get("useGusts") else "Vent moyen"
    shown = f"{value * factor:.0f} {symbol}"
    direction = f"{reading.get('dirLabel') or '—'} {reading.get('dir') or 0}°"

    def ready(key):
        last = state.get(key)
        return last is None or (time.time() - last) >= cooldown

    if is_above and not was_above and ready("last_upper"):
        state["last_upper"] = time.time()
        return {"title": f"Ça monte 🪁 {shown}",
                "body": f"{source} au-dessus de {upper * factor:.0f} {symbol} · {direction}"}, state

    if is_below and not was_below and ready("last_lower"):
        state["last_lower"] = time.time()
        return {"title": f"Ça tombe 🍃 {shown}",
                "body": f"{source} sous {lower * factor:.0f} {symbol} · {direction}"}, state

    return None, state


def push_all(cfg: dict, feed: dict, state: dict) -> dict:
    data = tokens()
    prefs = data.get("prefs", {})
    unit = prefs.get("unit", "kmh")
    reading = feed["current"]
    trend = [s["avg"] for s in feed.get("history", [])[-18:] if s.get("avg") is not None]
    body_state = content_state(reading, trend, unit)
    stale = iso_to_epoch(reading.get("t")) + 25 * 60

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
                                   start_payload(body_state, feed["balise"].get("name", "Balise"), stale),
                                   "liveactivity", ".push-type.liveactivity")
            log.info("push-to-start %s… → %s", token[:8], code)
            if code == 200:
                state["last_start"] = time.time()
                state["activity_started_at"] = time.time()
            else:
                log.warning("push-to-start refusé : %s", text[:160])
    elif delivered and not state.get("activity_started_at"):
        state["activity_started_at"] = time.time()

    # 3. alertes de seuil
    event, state = evaluate_alert(reading, prefs, state)
    if event:
        for token in data.get("device", []):
            code, text = apns_post(cfg, token, alert_payload(event["title"], event["body"]), "alert")
            log.info("alerte %s… → %s (%s)", token[:8], code, event["title"])
            if code == 410:
                drop_token("device", token)
            elif code != 200:
                log.warning("alerte refusée : %s", text[:160])

    state["last_push"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    state["pushed_reading"] = reading.get("t")
    return state


def pusher_loop():
    log.info("boucle pusher démarrée")
    while True:
        cfg = config()
        if not cfg:
            log.warning("config APNs absente (%s) — nouvel essai dans 5 min", CONFIG_PATH)
            time.sleep(300)
            continue

        feed = refresh_feed()
        if not feed:
            time.sleep(120)
            continue

        state = load_json(STATE_PATH, {})
        current_t = feed["current"].get("t")

        if current_t and current_t != state.get("pushed_reading"):
            log.info("nouveau relevé %s — %s km/h", current_t, feed["current"].get("avg"))
            try:
                state = push_all(cfg, feed, state)
            except Exception as exc:
                log.exception("échec du push : %s", exc)
            state["last_reading"] = current_t
            save_json(STATE_PATH, state)
            # le relevé suivant tombe ~10 min plus tard : on dort jusqu'à 20 s avant
            wait = iso_to_epoch(current_t) + 600 + 20 - time.time()
            time.sleep(max(60, min(wait, 700)))
        else:
            time.sleep(POLL_INTERVAL)


def main():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=pusher_loop, daemon=True).start()
    log.info("API LiveXWind sur le port %d", PORT)
    app.run(host="0.0.0.0", port=PORT, debug=False, use_reloader=False)


if __name__ == "__main__":
    main()
