#!/usr/bin/env python3
"""過去の掲載終了物件をGit履歴から抽出し、Supabaseにバックフィルする。

Git履歴の latest.json 全コミットを走査して、Supabaseに未登録の物件を
is_active=false で挿入する。latest_commute_v2_preview.json のエンリッチデータも
可能な限りオーバーレイする。
"""

from __future__ import annotations

import argparse
import json
import logging
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from report_utils import identity_key_str, normalize_listing_name, _normalize_address_for_key
from supabase_sync import _sanitize_value, _batch_upsert

logger = logging.getLogger(__name__)
JST = timezone(timedelta(hours=9))

RESULTS_DIR = Path(__file__).resolve().parent / "results"
DATA_DIR = Path(__file__).resolve().parent / "data"
REPO_ROOT = Path(__file__).resolve().parent.parent

ENRICHMENT_FIELDS = [
    "ss_lookup_status", "ss_profit_pct", "ss_oki_price_70m2", "ss_m2_discount",
    "ss_value_judgment", "ss_station_rank", "ss_ward_rank", "ss_sumai_surfin_url",
    "ss_appreciation_rate", "ss_favorite_count", "ss_purchase_judgment",
    "ss_radar_data", "ss_past_market_trends", "ss_surrounding_properties",
    "ss_price_judgments", "ss_sim_best_5yr", "ss_sim_best_10yr",
    "ss_sim_standard_5yr", "ss_sim_standard_10yr", "ss_sim_worst_5yr",
    "ss_sim_worst_10yr", "ss_loan_balance_5yr", "ss_loan_balance_10yr",
    "ss_sim_base_price", "ss_new_m2_price", "ss_forecast_m2_price",
    "ss_forecast_change_rate", "hazard_info", "commute_info", "commute_info_v2",
    "reinfolib_market_data", "mansion_review_data", "estat_population_data",
    "price_fairness_score", "resale_liquidity_score", "competing_listings_count",
    "listing_score", "floor_plan_images", "suumo_images",
    "investment_summary", "highlight_badge", "best_thumbnail_url",
    "extracted_features", "image_categories",
    "dedup_confidence", "alt_sources", "dedup_candidates",
    "key_strengths", "key_risks",
    "ai_recommendation_score", "ai_recommendation_summary",
    "ai_recommendation_flags", "ai_recommendation_action",
    "ai_recommendation_scenarios",
    "near_miss", "near_miss_reasons",
    "is_cheapest_in_building", "competing_price_range",
]


@dataclass
class PropertyRecord:
    item: dict
    identity_key: str
    first_commit_date: datetime
    last_commit_date: datetime
    source: str
    enrichment: dict = field(default_factory=dict)
    first_seen_at_override: str | None = None


def get_commit_hashes(limit: int | None = None) -> list[tuple[str, int]]:
    """latest.json を変更した非マージコミットを古い順に返す。"""
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "log", "--no-merges", "--format=%H %at",
         "--", "scraping-tool/results/latest.json"],
        capture_output=True, text=True,
    )
    pairs = []
    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        parts = line.split(" ", 1)
        if len(parts) == 2:
            pairs.append((parts[0], int(parts[1])))
    pairs.reverse()
    if limit:
        pairs = pairs[:limit]
    return pairs


def load_json_from_commit(commit_hash: str) -> list[dict]:
    result = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "show",
         f"{commit_hash}:scraping-tool/results/latest.json"],
        capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        return []
    try:
        data = json.loads(result.stdout)
        return data if isinstance(data, list) else []
    except (json.JSONDecodeError, ValueError):
        return []


def extract_from_git_history(
    limit: int | None = None, verbose: bool = False,
) -> dict[str, PropertyRecord]:
    """Git履歴を走査し、全物件の PropertyRecord を構築する。"""
    commits = get_commit_hashes(limit)
    logger.info("Git履歴走査: %d コミット", len(commits))

    records: dict[str, PropertyRecord] = {}
    for i, (commit_hash, commit_ts) in enumerate(commits):
        items = load_json_from_commit(commit_hash)
        if not items:
            continue
        commit_date = datetime.fromtimestamp(commit_ts, tz=timezone.utc)

        for item in items:
            ik = identity_key_str(item)
            if not ik or all(p in ("None", "") for p in ik.split("|")):
                continue

            if ik not in records:
                records[ik] = PropertyRecord(
                    item=dict(item),
                    identity_key=ik,
                    first_commit_date=commit_date,
                    last_commit_date=commit_date,
                    source=item.get("source", "suumo"),
                )
            else:
                records[ik].last_commit_date = commit_date
                records[ik].item.update(
                    {k: v for k, v in item.items() if v is not None}
                )
                if item.get("source"):
                    records[ik].source = item["source"]

        if verbose and (i + 1) % 50 == 0:
            logger.info("  %d/%d コミット処理済み (%d 物件)", i + 1, len(commits), len(records))

    logger.info("Git履歴から %d ユニーク物件を抽出", len(records))
    return records


def overlay_preview_data(records: dict[str, PropertyRecord]) -> int:
    """latest_commute_v2_preview.json のエンリッチデータをオーバーレイ。"""
    preview_path = RESULTS_DIR / "latest_commute_v2_preview.json"
    if not preview_path.exists():
        logger.warning("プレビューJSON未発見: %s", preview_path)
        return 0

    with open(preview_path) as f:
        preview_items = json.load(f)

    count = 0
    for item in preview_items:
        ik = identity_key_str(item)
        if not ik:
            continue

        if ik not in records:
            records[ik] = PropertyRecord(
                item=dict(item),
                identity_key=ik,
                first_commit_date=datetime.now(timezone.utc),
                last_commit_date=datetime.now(timezone.utc),
                source=item.get("source", "suumo"),
            )

        rec = records[ik]
        for field_name in ENRICHMENT_FIELDS:
            val = item.get(field_name)
            if val is not None:
                rec.enrichment[field_name] = val
        for key in ("latitude", "longitude", "suumo_images", "floor_plan_images"):
            if item.get(key) is not None:
                rec.item[key] = item[key]
        count += 1

    logger.info("プレビューJSONから %d 物件にエンリッチデータをオーバーレイ", count)
    return count


def resolve_first_seen_at(records: dict[str, PropertyRecord]) -> int:
    """first_seen_at.json から初回検出日を解決。旧キー形式を5要素プレフィックスでマッチ。"""
    fsa_path = DATA_DIR / "first_seen_at.json"
    if not fsa_path.exists():
        return 0

    with open(fsa_path) as f:
        fsa_data: dict[str, str] = json.load(f)

    prefix_map: dict[str, str] = {}
    for old_key, date_str in fsa_data.items():
        parts = old_key.split("|")
        if len(parts) >= 5:
            norm_name = normalize_listing_name(parts[0])
            norm_addr = _normalize_address_for_key(parts[3])
            prefix = f"{norm_name}|{parts[1]}|{parts[2]}|{norm_addr}|{parts[4]}"
            if prefix not in prefix_map or date_str < prefix_map[prefix]:
                prefix_map[prefix] = date_str

    count = 0
    for ik, rec in records.items():
        parts = ik.split("|")
        if len(parts) >= 5:
            lookup = "|".join(parts[:5])
            if lookup in prefix_map:
                rec.first_seen_at_override = prefix_map[lookup]
                count += 1

    logger.info("first_seen_at.json から %d 物件の初回検出日を解決", count)
    return count


def load_to_supabase(
    records: dict[str, PropertyRecord],
    dry_run: bool = False,
    verbose: bool = False,
) -> dict[str, int]:
    """Supabaseに未登録の物件を is_active=false で挿入する。"""
    from supabase_client import get_client

    summary = {"inserted": 0, "skipped": 0, "enriched": 0, "events": 0, "prices": 0}

    client = get_client()
    if not client:
        logger.error("Supabaseクライアント未初期化")
        return summary

    existing_keys: set[str] = set()
    offset = 0
    while True:
        resp = (client.table("listings")
                .select("identity_key")
                .range(offset, offset + 999)
                .execute())
        if not resp.data:
            break
        for row in resp.data:
            existing_keys.add(row["identity_key"])
        if len(resp.data) < 1000:
            break
        offset += 1000

    logger.info("Supabase既存物件: %d 件", len(existing_keys))

    to_insert = {ik: rec for ik, rec in records.items() if ik not in existing_keys}
    logger.info("新規挿入対象: %d 件 (スキップ: %d 件)",
                len(to_insert), len(records) - len(to_insert))

    if dry_run:
        summary["inserted"] = len(to_insert)
        summary["skipped"] = len(records) - len(to_insert)
        if verbose:
            for ik, rec in sorted(to_insert.items(), key=lambda x: x[1].item.get("name", "")):
                item = rec.item
                print(f"  [DRY] {item.get('name', '?')} | {item.get('price_man', '?')}万 | "
                      f"{item.get('layout', '?')} | {item.get('area_m2', '?')}㎡ | "
                      f"src={rec.source}")
        return summary

    for ik, rec in to_insert.items():
        item = rec.item
        first_seen = rec.first_seen_at_override or rec.first_commit_date.strftime("%Y-%m-%d")
        first_seen_ts = f"{first_seen}T00:00:00+09:00"
        last_seen_ts = rec.last_commit_date.isoformat()

        listing_row = {
            "identity_key": ik,
            "name": item.get("name", ""),
            "normalized_name": normalize_listing_name(item.get("name") or ""),
            "address": item.get("address"),
            "ss_address": item.get("ss_address"),
            "layout": item.get("layout"),
            "area_m2": item.get("area_m2"),
            "area_max_m2": item.get("area_max_m2"),
            "built_year": item.get("built_year"),
            "built_str": item.get("built_str"),
            "station_line": item.get("station_line"),
            "walk_min": item.get("walk_min"),
            "total_units": item.get("total_units"),
            "floor_position": item.get("floor_position"),
            "floor_total": item.get("floor_total"),
            "floor_structure": item.get("floor_structure"),
            "ownership": item.get("ownership"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "repair_fund_onetime": item.get("repair_fund_onetime"),
            "direction": item.get("direction"),
            "balcony_area_m2": item.get("balcony_area_m2"),
            "parking": item.get("parking"),
            "constructor": item.get("constructor"),
            "zoning": item.get("zoning"),
            "property_type": item.get("property_type", "chuko"),
            "developer_name": item.get("developer_name"),
            "developer_brokerage": item.get("developer_brokerage"),
            "list_ward_roman": item.get("list_ward_roman"),
            "delivery_date": item.get("delivery_date"),
            "duplicate_count": item.get("duplicate_count", 1),
            "latitude": item.get("latitude"),
            "longitude": item.get("longitude"),
            "feature_tags": item.get("feature_tags"),
            "is_active": False,
            "is_new": False,
            "is_new_building": False,
            "first_seen_at": first_seen,
            "first_seen_source": rec.source,
            "geocode_confidence": item.get("geocode_confidence"),
            "geocode_fixed": item.get("geocode_fixed"),
            "alt_urls": item.get("alt_urls"),
        }
        REAL_COLUMNS = {"area_m2", "area_max_m2", "balcony_area_m2", "latitude", "longitude"}
        listing_row = {
            k: v for k, v in _sanitize_value(listing_row).items()
            if v is not None or k in REAL_COLUMNS
        }

        try:
            (client.table("listings")
             .upsert(listing_row, on_conflict="identity_key", returning="minimal")
             .execute())
        except Exception as e:
            logger.error("listing upsert 失敗 (ik=%s): %s", ik[:60], e)
            continue

        id_resp = (client.table("listings")
                   .select("id")
                   .eq("identity_key", ik)
                   .execute())
        if not id_resp.data:
            logger.error("listing_id 取得失敗: %s", ik[:60])
            continue
        listing_id = id_resp.data[0]["id"]

        source_row = _sanitize_value({
            "listing_id": listing_id,
            "source": rec.source,
            "url": item.get("url", ""),
            "price_man": item.get("price_man"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "last_seen_at": last_seen_ts,
            "is_active": False,
            "consecutive_misses": 0,
        })
        source_row = {k: v for k, v in source_row.items() if v is not None}
        try:
            (client.table("listing_sources")
             .upsert(source_row, on_conflict="listing_id,source", returning="minimal")
             .execute())
        except Exception as e:
            logger.error("listing_sources upsert 失敗: %s", e)

        try:
            client.table("listing_events").insert(
                {"listing_id": listing_id, "source": rec.source,
                 "event_type": "appeared", "occurred_at": first_seen_ts},
                returning="minimal",
            ).execute()
            client.table("listing_events").insert(
                {"listing_id": listing_id, "source": rec.source,
                 "event_type": "removed", "occurred_at": last_seen_ts},
                returning="minimal",
            ).execute()
            summary["events"] += 2
        except Exception as e:
            logger.error("listing_events insert 失敗: %s", e)

        price_man = item.get("price_man")
        if price_man is not None:
            try:
                client.table("price_history").insert(
                    {"listing_id": listing_id, "source": rec.source,
                     "price_man": price_man, "recorded_at": first_seen_ts},
                    returning="minimal",
                ).execute()
                summary["prices"] += 1
            except Exception as e:
                logger.error("price_history insert 失敗: %s", e)

        if rec.enrichment:
            enrich_row = {"listing_id": listing_id}
            for ef in ENRICHMENT_FIELDS:
                val = rec.enrichment.get(ef)
                if val is not None:
                    enrich_row[ef] = val
            if len(enrich_row) > 1:
                enrich_row = _sanitize_value(enrich_row)
                try:
                    (client.table("enrichments")
                     .upsert(enrich_row, on_conflict="listing_id", returning="minimal")
                     .execute())
                    summary["enriched"] += 1
                except Exception as e:
                    logger.error("enrichments upsert 失敗: %s", e)

        summary["inserted"] += 1
        if verbose:
            logger.info("  挿入: %s (%s万)", item.get("name", "?"), item.get("price_man", "?"))

    summary["skipped"] = len(records) - len(to_insert)
    return summary


def verify(client) -> None:
    """投入後の検証クエリを実行。"""
    total = client.table("listings").select("id", count="exact").execute()
    active = (client.table("listings").select("id", count="exact")
              .eq("is_active", True).execute())
    inactive = (client.table("listings").select("id", count="exact")
                .eq("is_active", False).execute())
    print(f"\n=== 検証結果 ===")
    print(f"Supabase 全物件: {total.count}")
    print(f"  Active: {active.count}")
    print(f"  Inactive: {inactive.count}")

    check = (client.table("listings")
             .select("id, name, is_active, first_seen_at")
             .ilike("name", "%オークプレイス豊洲%")
             .execute())
    if check.data:
        for row in check.data:
            print(f"  オークプレイス豊洲: id={row['id']}, active={row['is_active']}, "
                  f"first_seen={row.get('first_seen_at')}")
    else:
        print("  オークプレイス豊洲: 未発見")

    enriched = client.rpc("", {}).execute()  # placeholder
    try:
        resp = client.table("enrichments").select("listing_id", count="exact").execute()
        print(f"  エンリッチメント件数: {resp.count}")
    except Exception:
        pass


def export_for_mcp(records: dict[str, PropertyRecord], output_path: str) -> None:
    """MCP経由でSupabaseに投入するためのJSONを出力する。"""
    export_data = []
    for ik, rec in records.items():
        item = rec.item
        first_seen = rec.first_seen_at_override or rec.first_commit_date.strftime("%Y-%m-%d")
        first_seen_ts = f"{first_seen}T00:00:00+09:00"
        last_seen_ts = rec.last_commit_date.isoformat()

        listing_row = {
            "identity_key": ik,
            "name": item.get("name", ""),
            "normalized_name": normalize_listing_name(item.get("name") or ""),
            "address": item.get("address"),
            "ss_address": item.get("ss_address"),
            "layout": item.get("layout"),
            "area_m2": item.get("area_m2"),
            "area_max_m2": item.get("area_max_m2"),
            "built_year": item.get("built_year"),
            "built_str": item.get("built_str"),
            "station_line": item.get("station_line"),
            "walk_min": item.get("walk_min"),
            "total_units": item.get("total_units"),
            "floor_position": item.get("floor_position"),
            "floor_total": item.get("floor_total"),
            "floor_structure": item.get("floor_structure"),
            "ownership": item.get("ownership"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "repair_fund_onetime": item.get("repair_fund_onetime"),
            "direction": item.get("direction"),
            "balcony_area_m2": item.get("balcony_area_m2"),
            "parking": item.get("parking"),
            "constructor": item.get("constructor"),
            "zoning": item.get("zoning"),
            "property_type": item.get("property_type", "chuko"),
            "developer_name": item.get("developer_name"),
            "developer_brokerage": item.get("developer_brokerage"),
            "list_ward_roman": item.get("list_ward_roman"),
            "delivery_date": item.get("delivery_date"),
            "duplicate_count": item.get("duplicate_count", 1),
            "latitude": item.get("latitude"),
            "longitude": item.get("longitude"),
            "feature_tags": item.get("feature_tags"),
            "is_active": False,
            "is_new": False,
            "is_new_building": False,
            "first_seen_at": first_seen,
            "first_seen_source": rec.source,
            "geocode_confidence": item.get("geocode_confidence"),
            "geocode_fixed": item.get("geocode_fixed"),
            "alt_urls": item.get("alt_urls"),
        }
        REAL_COLUMNS = {"area_m2", "area_max_m2", "balcony_area_m2", "latitude", "longitude"}
        listing_row = {
            k: v for k, v in _sanitize_value(listing_row).items()
            if v is not None or k in REAL_COLUMNS
        }

        source_row = {
            "source": rec.source,
            "url": item.get("url", ""),
            "price_man": item.get("price_man"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "last_seen_at": last_seen_ts,
            "is_active": False,
            "consecutive_misses": 0,
        }
        source_row = {k: v for k, v in _sanitize_value(source_row).items() if v is not None}

        enrichment = {}
        for ef in ENRICHMENT_FIELDS:
            val = rec.enrichment.get(ef)
            if val is not None:
                enrichment[ef] = val
        if enrichment:
            enrichment = _sanitize_value(enrichment)

        export_data.append({
            "listing": listing_row,
            "source": source_row,
            "enrichment": enrichment if enrichment else None,
            "first_seen_ts": first_seen_ts,
            "last_seen_ts": last_seen_ts,
        })

    with open(output_path, "w") as f:
        json.dump(export_data, f, ensure_ascii=False, indent=2, default=str)
    logger.info("エクスポート完了: %s (%d 件)", output_path, len(export_data))


def main():
    parser = argparse.ArgumentParser(description="過去物件をSupabaseにバックフィル")
    parser.add_argument("--dry-run", action="store_true", help="分析のみ、書き込まない")
    parser.add_argument("--preview-only", action="store_true", help="プレビューJSONのみ処理")
    parser.add_argument("--limit", type=int, help="処理するコミット数を制限")
    parser.add_argument("--verbose", action="store_true", help="詳細表示")
    parser.add_argument("--verify", action="store_true", help="投入後に検証クエリ実行")
    parser.add_argument("--export", type=str, help="MCP投入用JSONを出力するパス")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )

    if args.preview_only:
        records: dict[str, PropertyRecord] = {}
    else:
        records = extract_from_git_history(limit=args.limit, verbose=args.verbose)

    overlay_preview_data(records)
    resolve_first_seen_at(records)

    logger.info("=== サマリー ===")
    logger.info("全ユニーク物件: %d", len(records))

    if args.export:
        export_for_mcp(records, args.export)
        return

    summary = load_to_supabase(records, dry_run=args.dry_run, verbose=args.verbose)

    logger.info("=== 結果 ===")
    logger.info("挿入: %d, スキップ(既存): %d, エンリッチ: %d, イベント: %d, 価格履歴: %d",
                summary["inserted"], summary["skipped"], summary["enriched"],
                summary["events"], summary["prices"])

    if args.verify and not args.dry_run:
        from supabase_client import get_client
        client = get_client()
        if client:
            verify(client)


if __name__ == "__main__":
    main()
