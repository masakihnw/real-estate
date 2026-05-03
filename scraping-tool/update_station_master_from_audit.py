#!/usr/bin/env python3
"""
commute_auto_audit の結果から station_master_template.csv を再生成する。

audit 結果は Google Maps で実測した「駅→オフィス door-to-door」の所要時間。
min/med/max には実測値を中心にした現実的な幅を設定する。

使い方:
  python3 update_station_master_from_audit.py
  python3 update_station_master_from_audit.py --dry-run
"""

import argparse
import csv
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
AUDIT_DIR = ROOT / "commute_audit_results"
MASTER_CSV = ROOT.parent / "data" / "commute" / "station_master_template.csv"
STATIONS_CSV = ROOT.parent / "configs" / "commute" / "stations.csv"

OFFICES = ["playground", "m3career"]
SCENARIO = "wkday0900"
MIN_OFFSET = 3
MAX_OFFSET = 5


def load_audit_results() -> dict[str, dict[str, int]]:
    results: dict[str, dict[str, int]] = {}
    for office in OFFICES:
        path = AUDIT_DIR / f"audit_{office}.json"
        if path.exists():
            with open(path, encoding="utf-8") as f:
                results[office] = json.load(f)
        else:
            results[office] = {}
    return results


def load_station_ids() -> dict[str, str]:
    name_to_id: dict[str, str] = {}
    if STATIONS_CSV.exists():
        with open(STATIONS_CSV, encoding="utf-8") as f:
            reader = csv.DictReader(f)
            for row in reader:
                name_to_id[row["name"]] = row["station_id"]
    return name_to_id


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    audit = load_audit_results()
    station_ids = load_station_ids()

    all_stations: set[str] = set()
    for office in OFFICES:
        all_stations.update(audit[office].keys())

    rows: list[dict[str, str | int]] = []
    missing_ids: list[str] = []

    for station_name in sorted(all_stations):
        sid = station_ids.get(station_name, f"station-{station_name}")
        if station_name not in station_ids:
            missing_ids.append(station_name)

        for office in OFFICES:
            measured = audit[office].get(station_name)
            if measured is None:
                continue
            rows.append({
                "station_id": sid,
                "station": station_name,
                "office": office,
                "scenario": SCENARIO,
                "min": max(1, measured - MIN_OFFSET),
                "med": measured,
                "max": measured + MAX_OFFSET,
            })

    print(f"Audit stations: {len(all_stations)}")
    print(f"Output rows: {len(rows)}")
    if missing_ids:
        print(f"stations.csv に未登録: {', '.join(missing_ids[:10])}{'...' if len(missing_ids) > 10 else ''}")

    if args.dry_run:
        print("\n[dry-run] 書き込みをスキップ")
        for r in rows[:10]:
            print(f"  {r['station']} → {r['office']}: {r['min']}/{r['med']}/{r['max']}")
        return

    if MASTER_CSV.exists():
        backup = MASTER_CSV.with_suffix(".csv.bak")
        shutil.copy2(MASTER_CSV, backup)
        print(f"Backup: {backup}")

    with open(MASTER_CSV, "w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["station_id", "station", "office", "scenario", "min", "med", "max"])
        writer.writeheader()
        writer.writerows(rows)

    print(f"Updated: {MASTER_CSV}")


if __name__ == "__main__":
    main()
