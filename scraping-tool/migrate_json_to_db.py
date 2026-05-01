"""既存 JSON データを SQLite に移行するワンショットスクリプト。

実行:
    python3 migrate_json_to_db.py [--db data/listings.db]

対象:
    - results/latest.json → listings + listing_sources
    - results/latest_shinchiku.json → listings + listing_sources
    - data/first_seen_at.json → listing_sources.first_seen_at の上書き
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from db import get_db, upsert_listing, upsert_listing_source, record_event, _now_jst
from report_utils import identity_key_str, normalize_listing_name


def _load_json(path: str) -> list | dict:
    p = Path(path)
    if not p.exists():
        return [] if path.endswith(".json") else {}
    with open(p) as f:
        return json.load(f)


def migrate_listings(conn, listings: list[dict], first_seen_map: dict) -> dict:
    """Import listings into DB. Returns summary counts."""
    stats = {"imported": 0, "skipped": 0}

    for item in listings:
        ik = identity_key_str(item)
        if not ik or all(p in ("None", "") for p in ik.split("|")):
            stats["skipped"] += 1
            continue

        normalized_name = normalize_listing_name(item.get("name") or "")
        listing_data = {
            "name": item.get("name", ""),
            "normalized_name": normalized_name,
            "address": item.get("address"),
            "layout": item.get("layout"),
            "area_m2": item.get("area_m2"),
            "built_year": item.get("built_year"),
            "built_str": item.get("built_str"),
            "station_line": item.get("station_line"),
            "walk_min": item.get("walk_min"),
            "total_units": item.get("total_units"),
            "floor_position": item.get("floor_position"),
            "floor_total": item.get("floor_total"),
            "floor_structure": item.get("floor_structure"),
            "ownership": item.get("ownership"),
            "property_type": item.get("property_type", "chuko"),
            "developer_name": item.get("developer_name"),
            "developer_brokerage": item.get("developer_brokerage"),
        }

        listing_id = upsert_listing(conn, ik, listing_data)

        source = item.get("source", "suumo")
        now = _now_jst()

        first_seen_at = _resolve_first_seen(item, ik, first_seen_map, now)

        source_data = {
            "url": item.get("url", ""),
            "price_man": item.get("price_man"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "listing_agent": item.get("listing_agent"),
            "is_motodzuke": item.get("is_motodzuke"),
        }

        existing_source = conn.execute(
            "SELECT id FROM listing_sources WHERE listing_id = ? AND source = ?",
            (listing_id, source),
        ).fetchone()

        if existing_source:
            conn.execute(
                """UPDATE listing_sources
                   SET url = ?, price_man = ?, management_fee = ?,
                       repair_reserve_fund = ?, listing_agent = ?, is_motodzuke = ?,
                       first_seen_at = ?, last_seen_at = ?, is_active = 1
                   WHERE id = ?""",
                (
                    source_data["url"], source_data["price_man"],
                    source_data["management_fee"], source_data["repair_reserve_fund"],
                    source_data["listing_agent"], source_data["is_motodzuke"],
                    first_seen_at, now, existing_source["id"],
                ),
            )
        else:
            conn.execute(
                """INSERT INTO listing_sources
                   (listing_id, source, url, price_man, management_fee,
                    repair_reserve_fund, listing_agent, is_motodzuke,
                    first_seen_at, last_seen_at, is_active)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)""",
                (
                    listing_id, source, source_data["url"],
                    source_data["price_man"], source_data["management_fee"],
                    source_data["repair_reserve_fund"],
                    source_data["listing_agent"], source_data["is_motodzuke"],
                    first_seen_at, now,
                ),
            )
            record_event(conn, listing_id, source, "appeared")

        # Import enrichment data if available
        _import_enrichment(conn, listing_id, item)

        stats["imported"] += 1

    return stats


def _resolve_first_seen(item: dict, ik: str, first_seen_map: dict, fallback: str) -> str:
    """Determine first_seen_at from various sources."""
    # 1. Item-level first_seen_at (injected by finalize pipeline)
    item_first = item.get("first_seen_at")
    if item_first:
        if len(item_first) == 10:
            return item_first + "T00:00:00+09:00"
        return item_first

    # 2. first_seen_at.json lookup by identity_key_str
    if ik in first_seen_map:
        val = first_seen_map[ik]
        if isinstance(val, str):
            if len(val) == 10:
                return val + "T00:00:00+09:00"
            return val
        if isinstance(val, dict):
            fs = val.get("first_seen", "")
            if fs:
                if len(fs) == 10:
                    return fs + "T00:00:00+09:00"
                return fs

    return fallback


def _import_enrichment(conn, listing_id: int, item: dict) -> None:
    """Import enrichment-related fields into the enrichments table."""
    has_enrichment = any(
        item.get(k) is not None
        for k in ("latitude", "longitude", "commute_info", "ss_appreciation_rate")
    )
    if not has_enrichment:
        return

    commute_json = None
    if item.get("commute_info_v2"):
        commute_json = json.dumps(item["commute_info_v2"], ensure_ascii=False)
    elif item.get("commute_info"):
        commute_json = json.dumps(item["commute_info"], ensure_ascii=False)

    conn.execute(
        """INSERT OR REPLACE INTO enrichments
           (listing_id, latitude, longitude, commute_m3,
            ss_appreciation_rate, ss_deviation, updated_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (
            listing_id,
            item.get("latitude"),
            item.get("longitude"),
            commute_json,
            item.get("ss_appreciation_rate"),
            item.get("ss_deviation"),
            _now_jst(),
        ),
    )


def main():
    parser = argparse.ArgumentParser(description="Migrate JSON data to SQLite")
    parser.add_argument("--db", default=None, help="DB path (default: data/listings.db)")
    parser.add_argument("--latest", default="results/latest.json")
    parser.add_argument("--latest-shinchiku", default="results/latest_shinchiku.json")
    parser.add_argument("--first-seen", default="data/first_seen_at.json")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    print("=== JSON → SQLite 移行 ===", file=sys.stderr)

    first_seen_map = _load_json(args.first_seen)
    if isinstance(first_seen_map, list):
        first_seen_map = {}

    conn = get_db(args.db)

    if args.dry_run:
        print("(dry-run mode: changes will be rolled back)", file=sys.stderr)

    # Migrate chuko listings
    chuko = _load_json(args.latest)
    if chuko:
        print(f"中古: {len(chuko)} 件をインポート中...", file=sys.stderr)
        stats = migrate_listings(conn, chuko, first_seen_map)
        print(f"  imported={stats['imported']}, skipped={stats['skipped']}", file=sys.stderr)
    else:
        print("中古: latest.json が見つかりません（スキップ）", file=sys.stderr)

    # Migrate shinchiku listings
    shinchiku = _load_json(args.latest_shinchiku)
    if shinchiku:
        print(f"新築: {len(shinchiku)} 件をインポート中...", file=sys.stderr)
        stats = migrate_listings(conn, shinchiku, first_seen_map)
        print(f"  imported={stats['imported']}, skipped={stats['skipped']}", file=sys.stderr)
    else:
        print("新築: latest_shinchiku.json が見つかりません（スキップ）", file=sys.stderr)

    # Summary
    total = conn.execute("SELECT COUNT(*) AS cnt FROM listings").fetchone()["cnt"]
    sources = conn.execute("SELECT COUNT(*) AS cnt FROM listing_sources").fetchone()["cnt"]
    enriched = conn.execute("SELECT COUNT(*) AS cnt FROM enrichments").fetchone()["cnt"]
    print(f"\n=== 移行完了 ===", file=sys.stderr)
    print(f"  listings: {total}", file=sys.stderr)
    print(f"  listing_sources: {sources}", file=sys.stderr)
    print(f"  enrichments: {enriched}", file=sys.stderr)

    if args.dry_run:
        conn.rollback()
        print("(rolled back)", file=sys.stderr)
    else:
        conn.commit()
    conn.close()


if __name__ == "__main__":
    main()
