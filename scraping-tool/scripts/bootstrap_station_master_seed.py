#!/usr/bin/env python3
"""
既存の commute_*.json と station_cache.json から
Phase1 用の Station Master seed を自動生成する。
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import unicodedata
from pathlib import Path


def slugify_station_id(name: str) -> str:
    normalized = unicodedata.normalize("NFKC", name).strip().lower()
    normalized = normalized.replace("ヶ", "ケ")
    normalized = re.sub(r"[\\s/／・()（）]+", "-", normalized)
    normalized = normalized.strip("-")
    normalized = re.sub(r"-{2,}", "-", normalized)
    return f"station-{normalized}" if normalized else "station-unknown"


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def load_existing_station_rows(path: Path) -> dict[str, dict[str, str]]:
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as f:
        reader = csv.DictReader(f)
        return {row["name"]: row for row in reader}


def load_existing_master_rows(path: Path) -> dict[tuple[str, str, str], dict[str, str]]:
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as f:
        reader = csv.DictReader(f)
        return {(row["station"], row["office"], row["scenario"]): row for row in reader}


def write_csv(path: Path, fieldnames: list[str], rows: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description="Station Master seed bootstrap")
    parser.add_argument("--station-cache", default="scraping-tool/data/station_cache.json")
    parser.add_argument("--playground-json", default="scraping-tool/data/commute_playground.json")
    parser.add_argument("--m3career-json", default="scraping-tool/data/commute_m3career.json")
    parser.add_argument("--stations-csv", default="configs/commute/stations.csv")
    parser.add_argument("--station-master-csv", default="data/commute/station_master_template.csv")
    args = parser.parse_args()

    station_cache = load_json(Path(args.station_cache))
    playground = load_json(Path(args.playground_json))
    m3career = load_json(Path(args.m3career_json))

    station_names = sorted(set(playground) | set(m3career))
    existing_stations = load_existing_station_rows(Path(args.stations_csv))
    existing_master = load_existing_master_rows(Path(args.station_master_csv))

    station_rows: dict[str, dict[str, object]] = {}
    master_rows: dict[tuple[str, str, str], dict[str, object]] = {}

    added_station_count = 0
    added_master_count = 0
    missing_coordinates: list[str] = []

    for station_name in station_names:
        coords = station_cache.get(station_name)
        station_id = slugify_station_id(station_name)
        existing_station = existing_stations.get(station_name)
        if coords and len(coords) == 2:
            station_rows[station_name] = {
                "station_id": station_id,
                "name": station_name,
                "lat": existing_station["lat"] if existing_station and existing_station.get("lat") else f"{coords[0]:.7f}",
                "lng": existing_station["lng"] if existing_station and existing_station.get("lng") else f"{coords[1]:.7f}",
            }
            if existing_station is None:
                added_station_count += 1
        if not coords or len(coords) != 2:
            missing_coordinates.append(station_name)

        scenario = "wkday0900"
        pg_minutes = playground.get(station_name)
        if isinstance(pg_minutes, int):
            key = (station_name, "playground", scenario)
            existing_row = existing_master.get(key)
            if key not in master_rows:
                master_rows[key] = {
                    "station_id": station_id,
                    "station": station_name,
                    "office": "playground",
                    "scenario": scenario,
                    "min": existing_row["min"] if existing_row else max(1, pg_minutes - 4),
                    "med": existing_row["med"] if existing_row else pg_minutes,
                    "max": existing_row["max"] if existing_row else pg_minutes + 6,
                }
                if existing_row is None:
                    added_master_count += 1

        m3_minutes = m3career.get(station_name)
        if isinstance(m3_minutes, int):
            key = (station_name, "m3career", scenario)
            existing_row = existing_master.get(key)
            if key not in master_rows:
                master_rows[key] = {
                    "station_id": station_id,
                    "station": station_name,
                    "office": "m3career",
                    "scenario": scenario,
                    "min": existing_row["min"] if existing_row else max(1, m3_minutes - 4),
                    "med": existing_row["med"] if existing_row else m3_minutes,
                    "max": existing_row["max"] if existing_row else m3_minutes + 6,
                }
                if existing_row is None:
                    added_master_count += 1

    ordered_station_rows = sorted(station_rows.values(), key=lambda row: (str(row["name"]), str(row["station_id"])))
    ordered_master_rows = sorted(
        master_rows.values(),
        key=lambda row: (str(row["station"]), str(row["office"]), str(row["scenario"])),
    )

    write_csv(
        Path(args.stations_csv),
        ["station_id", "name", "lat", "lng"],
        ordered_station_rows,
    )
    write_csv(
        Path(args.station_master_csv),
        ["station_id", "station", "office", "scenario", "min", "med", "max"],
        ordered_master_rows,
    )

    print(
        json.dumps(
            {
                "stations_total": len(ordered_station_rows),
                "station_master_total": len(ordered_master_rows),
                "stations_added": added_station_count,
                "station_master_added": added_master_count,
                "missing_coordinates_count": len(missing_coordinates),
                "missing_coordinates_sample": missing_coordinates[:20],
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
