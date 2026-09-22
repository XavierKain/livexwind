#!/usr/bin/env python3
"""
Cadence de publication d'une balise, déduite de ses relevés.

Volontairement sans dépendance : c'est de la logique sur les données, pas du
serveur, et elle doit rester testable partout.
"""

from __future__ import annotations

from datetime import datetime, timezone

MIN_PERIOD = 55     # aucune source observée ne publie plus vite
MAX_PERIOD = 2400   # meteo.cat publie au pas semi-horaire
DEFAULT_PERIOD = 600


def observed_period(history: list) -> int:
    """Cadence réelle de publication, déduite des derniers relevés.

    Elle varie d'une station à l'autre — windguru publie à la minute, une balise
    FFVL toutes les 10 min — et parfois pour une même source. On la mesure donc
    au lieu de la supposer.

    On retient le **plus petit** écart récent, pas la médiane : un trou de
    transmission allonge un écart, jamais l'inverse. C'est aussi ce qui fait
    converger vite une station dont l'historique initial a été rééchantillonné
    à 10 min alors qu'elle publie chaque minute.
    """
    stamps = []
    for sample in history[-14:]:
        try:
            stamps.append(datetime.fromisoformat(sample["t"].replace("Z", "+00:00")))
        except (KeyError, ValueError, AttributeError, TypeError):
            continue

    gaps = [(b - a).total_seconds() for a, b in zip(stamps, stamps[1:])
            if MIN_PERIOD <= (b - a).total_seconds() <= MAX_PERIOD]
    return int(min(gaps)) if gaps else DEFAULT_PERIOD


# Silence : au bout de combien de temps sans relevé une balise n'émet plus.
SILENCE_FLOOR = 180        # jamais plus sévère que trois minutes
SILENCE_CEILING = 3 * 3600  # au-delà, muette quel que soit son rythme
SILENCE_MARGIN = 1.5


def silence_after(history: list) -> int:
    """Durée de silence au-delà de laquelle la balise ne publie plus.

    Ce n'est **pas** sa cadence. `observed_period` retient le plus petit écart,
    ce qu'il faut pour savoir quand la relire ; s'en servir pour juger son
    silence revient à exiger d'elle son meilleur rythme en permanence. Mesuré
    sur Tarifa / Campo de Futbol : écarts de 60 s à 540 s, cadence déduite 60 s,
    donc « hors ligne » 38 fois sur 59 — pour une station qui n'a jamais cessé
    d'émettre.

    On part donc du plus **grand** écart récent, celui qu'elle s'autorise
    vraiment, et on lui laisse une marge par-dessus.
    """
    stamps = []
    for sample in history[-30:]:
        try:
            stamps.append(datetime.fromisoformat(
                sample["t"].replace("Z", "+00:00")).timestamp())
        except (KeyError, ValueError, AttributeError, TypeError):
            continue

    gaps = [b - a for a, b in zip(stamps, stamps[1:])
            if MIN_PERIOD <= (b - a) <= MAX_PERIOD]
    if not gaps:
        return DEFAULT_PERIOD * 2 + 60
    return int(min(SILENCE_CEILING, max(SILENCE_FLOOR, max(gaps) * SILENCE_MARGIN + 60)))


# Au-delà d'une heure sans relevé, ce n'est plus un intervalle de publication :
# c'est un trou. Aucune source suivie ne publie aussi lentement.
GAP_SECONDS = 3600


def worst_gap(history: list, now: datetime | None = None) -> float | None:
    """Début du plus long trou de la courbe (epoch), ou None s'il n'y en a pas.

    L'instant présent compte comme dernier point : c'est ce qui fait voir le
    trou quand c'est la relève elle-même qui s'est arrêtée, et non la station.

    Sert à décider s'il faut redemander l'historique à la source. La valeur
    renvoyée identifie le trou autant qu'elle le signale : tant qu'elle ne
    change pas, c'est le même creux, et inutile de le redemander deux fois.
    """
    reference = (now or datetime.now(timezone.utc)).timestamp()
    stamps = []
    for sample in history:
        try:
            stamps.append(datetime.fromisoformat(
                sample["t"].replace("Z", "+00:00")).timestamp())
        except (KeyError, ValueError, AttributeError, TypeError):
            continue
    stamps.append(reference)

    start, widest = None, GAP_SECONDS
    for a, b in zip(stamps, stamps[1:]):
        if b - a > widest:
            start, widest = a, b - a
    return start


# Le graphe de l'app va jusqu'à 24 h, mais une station qui publie à la minute
# produit 2 880 points sur 48 h — un flux de 300 Ko rechargé par le téléphone, la
# montre et le widget à chaque relevé. On garde donc le détail là où on le
# regarde, et on l'allège en remontant dans le temps.
FULL_DETAIL_HOURS = 3
MEDIUM_DETAIL_HOURS = 12
MEDIUM_STEP_SECONDS = 5 * 60
COARSE_STEP_SECONDS = 15 * 60


def thin_history(history: list, now: datetime | None = None) -> list:
    """Réduit l'historique sans toucher au passé récent.

    Résolution pleine sur les 3 dernières heures, un point toutes les 5 min
    jusqu'à 12 h, puis toutes les 15 min au-delà.
    """
    if not history:
        return history

    reference = now or datetime.now(timezone.utc)
    kept: list = []
    last_kept_at: dict = {}

    for sample in history:
        try:
            moment = datetime.fromisoformat(sample["t"].replace("Z", "+00:00"))
        except (KeyError, ValueError, AttributeError, TypeError):
            continue

        age_hours = (reference - moment).total_seconds() / 3600
        if age_hours <= FULL_DETAIL_HOURS:
            kept.append(sample)
            continue

        step = MEDIUM_STEP_SECONDS if age_hours <= MEDIUM_DETAIL_HOURS else COARSE_STEP_SECONDS
        bucket = int(moment.timestamp() // step)
        if last_kept_at.get(step) != bucket:
            last_kept_at[step] = bucket
            kept.append(sample)

    return kept
