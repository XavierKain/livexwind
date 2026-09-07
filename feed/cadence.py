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
