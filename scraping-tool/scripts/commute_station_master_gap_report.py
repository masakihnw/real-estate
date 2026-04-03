#!/usr/bin/env python3
"""
Station Master の不足駅・候補ゼロ物件を可視化する補助スクリプト。
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from commute_station_master_enricher import (
    build_station_candidates,
    load_listings,
    load_offices,
    load_station_master,
    load_stations,
)


def main() -> None:
    parser = argparse.ArgumentParser(description="Station Master の不足駅レポート")
    parser.add_argument("--input", required=True)
    parser.add_argument("--stations-csv", required=True)
    parser.add_argument("--station-master-csv", required=True)
    parser.add_argument("--offices-yaml", required=True)
    parser.add_argument("--candidate-k", type=int, default=4)
    parser.add_argument("--radius-m", type=int, default=2000)
    parser.add_argument("--output-csv")
    args = parser.parse_args()

    listings = load_listings(Path(args.input))
    stations = load_stations(Path(args.stations_csv))
    master_rows = load_station_master(Path(args.station_master_csv))
    offices = load_offices(Path(args.offices_yaml))

    candidate_zero_rows: list[dict[str, object]] = []
    master_gap_rows: list[dict[str, object]] = []
    missing_station_counter: Counter[str] = Counter()

    for listing in listings:
        if listing.get("latitude") is None or listing.get("longitude") is None:
            continue

        candidates = build_station_candidates(
            listing,
            stations,
            radius_m=args.radius_m,
            candidate_k=args.candidate_k,
        )
        if not candidates:
            candidate_zero_rows.append(
                {
                    "property_id": listing.get("property_id") or listing.get("id") or "",
                    "name": listing.get("name") or "",
                    "latitude": listing.get("latitude"),
                    "longitude": listing.get("longitude"),
                    "issue": "candidate_zero",
                }
            )
            continue

        for office_id in offices.keys():
            if any((station.station_id, office_id) in master_rows for station, _distance in candidates):
                continue

            station_names = [station.name for station, _distance in candidates]
            for station_name in station_names:
                missing_station_counter[station_name] += 1

            master_gap_rows.append(
                {
                    "property_id": listing.get("property_id") or listing.get("id") or "",
                    "name": listing.get("name") or "",
                    "office_id": office_id,
                    "candidate_stations": " / ".join(station_names),
                    "issue": "master_miss",
                }
            )

    summary = {
        "candidate_zero_count": len(candidate_zero_rows),
        "master_miss_count": len(master_gap_rows),
        "top_missing_stations": missing_station_counter.most_common(10),
    }
    print(json.dumps(summary, ensure_ascii=False))

    if args.output_csv:
        output_path = Path(args.output_csv)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        fieldnames = ["property_id", "name", "office_id", "candidate_stations", "latitude", "longitude", "issue"]
        with output_path.open("w", encoding="utf-8", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()
            for row in candidate_zero_rows + master_gap_rows:
                writer.writerow(row)


if __name__ == "__main__":
    main()
