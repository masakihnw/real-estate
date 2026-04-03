#!/usr/bin/env python3
"""
Phase 1 の Station Master ベース通勤 enricher。

物件 JSON に commute_info_v2 を付与する。
計算式:
  物件 -> 候補駅 徒歩 + Station Master 中央値 + オフィス最終徒歩 + バッファ

使い方:
  python3 commute_station_master_enricher.py \
    --input results/latest.json \
    --output results/latest.json \
    --stations-csv ../configs/commute/stations.csv \
    --station-master-csv ../data/commute/station_master_template.csv \
    --offices-yaml ../configs/commute/offices.yaml
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - optional dependency
    yaml = None

from logger import get_logger

logger = get_logger(__name__)

JST = timezone(timedelta(hours=9))


@dataclass(frozen=True)
class Station:
    station_id: str
    name: str
    lat: float
    lng: float


@dataclass(frozen=True)
class Office:
    office_id: str
    office_name: str
    last_walk_minutes: int


@dataclass(frozen=True)
class MasterRow:
    station_id: str
    station_name: str
    office_id: str
    scenario: str
    min_minutes: int
    med_minutes: int
    max_minutes: int


def haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    radius = 6_371_000.0
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lng2 - lng1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * radius * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def load_stations(path: Path) -> list[Station]:
    rows: list[Station] = []
    with path.open(encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(
                Station(
                    station_id=row["station_id"].strip(),
                    name=row["name"].strip(),
                    lat=float(row["lat"]),
                    lng=float(row["lng"]),
                )
            )
    return rows


def load_offices(path: Path) -> dict[str, Office]:
    if yaml is not None:
        with path.open(encoding="utf-8") as f:
            raw = yaml.safe_load(f) or {}
    else:
        raw = _load_simple_yaml(path)

    offices: dict[str, Office] = {}
    for office_id, item in raw.items():
        offices[office_id] = Office(
            office_id=office_id,
            office_name=item.get("office_name", office_id),
            last_walk_minutes=int(item["last_walk_minutes"]),
        )
    return offices


def _load_simple_yaml(path: Path) -> dict[str, dict[str, Any]]:
    """PyYAML がない環境向けの最小 YAML パーサー。"""
    root: dict[str, dict[str, Any]] = {}
    current_key: str | None = None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip()
        if not line or line.lstrip().startswith("#"):
            continue

        if not line.startswith(" ") and line.endswith(":"):
            current_key = line[:-1].strip()
            root[current_key] = {}
            continue

        if current_key is None:
            continue

        stripped = line.strip()
        if ":" not in stripped:
            continue
        key, value = stripped.split(":", 1)
        value = value.strip().strip("'\"")
        if value.isdigit():
            parsed: Any = int(value)
        else:
            try:
                parsed = float(value)
            except ValueError:
                parsed = value
        root[current_key][key.strip()] = parsed

    return root


def load_station_master(path: Path) -> dict[tuple[str, str], MasterRow]:
    rows: dict[tuple[str, str], MasterRow] = {}
    with path.open(encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = (row["station_id"].strip(), row["office"].strip())
            rows[key] = MasterRow(
                station_id=row["station_id"].strip(),
                station_name=row["station"].strip(),
                office_id=row["office"].strip(),
                scenario=row["scenario"].strip(),
                min_minutes=int(row["min"]),
                med_minutes=int(row["med"]),
                max_minutes=int(row["max"]),
            )
    return rows


def load_listings(path: Path) -> list[dict[str, Any]]:
    if path.suffix.lower() == ".csv":
        return load_listings_csv(path)

    with path.open(encoding="utf-8") as f:
        loaded = json.load(f)
    if not isinstance(loaded, list):
        raise ValueError("input JSON must be a list of listings")
    return loaded


def load_listings_csv(path: Path) -> list[dict[str, Any]]:
    listings: list[dict[str, Any]] = []
    with path.open(encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            lat_raw = row.get("latitude") or row.get("lat")
            lng_raw = row.get("longitude") or row.get("lng")
            listing: dict[str, Any] = dict(row)
            if lat_raw not in (None, ""):
                listing["latitude"] = float(lat_raw)
            if lng_raw not in (None, ""):
                listing["longitude"] = float(lng_raw)

            override_raw = row.get("walk_override_min")
            if override_raw not in (None, ""):
                listing["walk_override_min"] = int(override_raw)

            listings.append(listing)
    return listings


def walk_override_minutes(listing: dict[str, Any]) -> int | None:
    raw = listing.get("walk_override_min")
    if raw in (None, "", 0):
        return None
    return int(raw)


def build_station_candidates(
    listing: dict[str, Any],
    stations: list[Station],
    radius_m: int,
    candidate_k: int,
) -> list[tuple[Station, float]]:
    lat = listing.get("latitude")
    lng = listing.get("longitude")
    if lat is None or lng is None:
        return []

    pairs: list[tuple[Station, float]] = []
    for station in stations:
        distance_m = haversine_m(float(lat), float(lng), station.lat, station.lng)
        if distance_m <= radius_m:
            pairs.append((station, distance_m))

    pairs.sort(key=lambda item: item[1])
    return pairs[:candidate_k]


def build_office_estimate(
    listing: dict[str, Any],
    office: Office,
    candidates: list[tuple[Station, float]],
    master_rows: dict[tuple[str, str], MasterRow],
    walk_speed_m_per_min: float,
    detour_factor: float,
    buffer_min: int,
) -> dict[str, Any] | None:
    best: dict[str, Any] | None = None
    override = walk_override_minutes(listing)

    for station, distance_m in candidates:
        master = master_rows.get((station.station_id, office.office_id))
        if master is None:
            continue

        walk_minutes = override if override is not None else math.ceil(distance_m * detour_factor / walk_speed_m_per_min)
        representative = walk_minutes + master.med_minutes + office.last_walk_minutes + buffer_min
        range_min = walk_minutes + master.min_minutes + office.last_walk_minutes + buffer_min
        range_max = walk_minutes + master.max_minutes + office.last_walk_minutes + buffer_min

        current = {
            "representative_minutes": representative,
            "range_minutes": {"min": range_min, "max": range_max},
            "representative_stat": "median",
            "selected_station": {
                "station_id": station.station_id,
                "name": station.name,
                "distance_m": round(distance_m, 1),
            },
            "components": {
                "walk_origin_to_station": walk_minutes,
                "station_to_office_master": master.med_minutes,
                "office_last_walk": office.last_walk_minutes,
                "buffer": buffer_min,
            },
            "quality": {
                "label": "high",
                "source": "station_master",
                "fallback_used": False,
            },
        }

        if best is None or representative < best["representative_minutes"]:
            best = current

    return best


def build_commute_info_v2(
    listing: dict[str, Any],
    offices: dict[str, Office],
    stations: list[Station],
    master_rows: dict[tuple[str, str], MasterRow],
    candidate_k: int,
    radius_m: int,
    walk_speed_m_per_min: float,
    detour_factor: float,
    buffer_min: int,
    ttl_days: int,
) -> str | None:
    candidates = build_station_candidates(listing, stations, radius_m=radius_m, candidate_k=candidate_k)
    if not candidates:
        return None

    offices_payload: dict[str, Any] = {}
    for office_id, office in offices.items():
        estimate = build_office_estimate(
            listing=listing,
            office=office,
            candidates=candidates,
            master_rows=master_rows,
            walk_speed_m_per_min=walk_speed_m_per_min,
            detour_factor=detour_factor,
            buffer_min=buffer_min,
        )
        if estimate is not None:
            offices_payload[office_id] = estimate

    if not offices_payload:
        return None

    now = datetime.now(JST)
    payload = {
        "schema_version": 2,
        "algo_version": "station_master_v1",
        "computed_at": now.isoformat(),
        "expires_at": (now + timedelta(days=ttl_days)).isoformat(),
        "offices": offices_payload,
    }
    return json.dumps(payload, ensure_ascii=False)


def enrich(
    listings: list[dict[str, Any]],
    offices: dict[str, Office],
    stations: list[Station],
    master_rows: dict[tuple[str, str], MasterRow],
    candidate_k: int,
    radius_m: int,
    walk_speed_m_per_min: float,
    detour_factor: float,
    buffer_min: int,
    ttl_days: int,
    force: bool,
) -> dict[str, int]:
    done = 0
    candidate_zero = 0
    master_miss = 0

    for listing in listings:
        if listing.get("commute_info_v2") and not force:
            continue
        if listing.get("latitude") is None or listing.get("longitude") is None:
            continue

        candidates = build_station_candidates(listing, stations, radius_m=radius_m, candidate_k=candidate_k)
        if not candidates:
            candidate_zero += 1
            continue

        encoded = build_commute_info_v2(
            listing=listing,
            offices=offices,
            stations=stations,
            master_rows=master_rows,
            candidate_k=candidate_k,
            radius_m=radius_m,
            walk_speed_m_per_min=walk_speed_m_per_min,
            detour_factor=detour_factor,
            buffer_min=buffer_min,
            ttl_days=ttl_days,
        )
        if encoded is None:
            master_miss += 1
            continue

        listing["commute_info_v2"] = encoded
        done += 1

    return {
        "done": done,
        "cand0": candidate_zero,
        "master_miss": master_miss,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Station Master ベース通勤 enricher")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--stations-csv", required=True)
    parser.add_argument("--station-master-csv", required=True)
    parser.add_argument("--offices-yaml", required=True)
    parser.add_argument("--candidate-k", type=int, default=4)
    parser.add_argument("--radius-m", type=int, default=2000)
    parser.add_argument("--walk-speed-m-per-min", type=float, default=80.0)
    parser.add_argument("--detour-factor", type=float, default=1.3)
    parser.add_argument("--buffer-min", type=int, default=4)
    parser.add_argument("--ttl-days", type=int, default=14)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    listings = load_listings(Path(args.input))

    result = enrich(
        listings=listings,
        offices=load_offices(Path(args.offices_yaml)),
        stations=load_stations(Path(args.stations_csv)),
        master_rows=load_station_master(Path(args.station_master_csv)),
        candidate_k=args.candidate_k,
        radius_m=args.radius_m,
        walk_speed_m_per_min=args.walk_speed_m_per_min,
        detour_factor=args.detour_factor,
        buffer_min=args.buffer_min,
        ttl_days=args.ttl_days,
        force=args.force,
    )

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    logger.info(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
