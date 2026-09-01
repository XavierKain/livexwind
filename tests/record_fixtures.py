#!/usr/bin/env python3
"""Régénère les fixtures depuis les sources réelles. À relancer quand un format change."""
import json, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "feed"))
import scrape, windmorbihan, windguru

fx = pathlib.Path(__file__).resolve().parent / "fixtures"
fx.mkdir(exist_ok=True)
(fx / "balisemeteo_64.html").write_text(scrape.fetch(64), encoding="utf-8")
(fx / "windmorbihan_latest.json").write_text(json.dumps(windmorbihan._latest_map(force=True), ensure_ascii=False))
(fx / "windmorbihan_sensors.json").write_text(json.dumps(windmorbihan.sensors(force=True), ensure_ascii=False))
(fx / "windguru_station_2667.json").write_text(json.dumps(windguru.station(2667), ensure_ascii=False))
(fx / "windguru_current_2667.json").write_text(json.dumps(windguru._get("q=station_data_current&id_station=2667"), ensure_ascii=False))
print("fixtures régénérées — pense à reconstruire la page masquée (voir fixtures/README.md)")
