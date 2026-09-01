#!/usr/bin/env python3
"""
Cadence de publication d'une balise, déduite de ses relevés.

Volontairement sans dépendance : c'est de la logique sur les données, pas du
serveur, et elle doit rester testable partout.
"""

from __future__ import annotations

from datetime import datetime

MIN_PERIOD = 55     # aucune source observée ne publie plus vite
MAX_PERIOD = 900
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
