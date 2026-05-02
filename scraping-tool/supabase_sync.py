"""Supabase への物件データ同期モジュール。

既存の db.py (SQLite) と同等のロジックで、Supabase (Postgres) に
物件・ソース・価格履歴・イベントを書き込む。

メインエントリ: sync_to_supabase(output_dir)
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from supabase_client import get_client

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))
BATCH_SIZE = 500


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_json(path: str) -> list[dict]:
    p = Path(path)
    if not p.exists() or p.stat().st_size == 0:
        return []
    with open(p) as f:
        data = json.load(f)
    return data if isinstance(data, list) else []


def _batch_upsert(client, table: str, rows: list[dict], on_conflict: str) -> int:
    """バッチ upsert。BATCH_SIZE ごとに分割して送信。"""
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        batch = rows[i:i + BATCH_SIZE]
        resp = client.table(table).upsert(batch, on_conflict=on_conflict).execute()
        total += len(resp.data) if resp.data else 0
    return total


def _sync_source_listings(client, listings: list[dict], source: str, property_type: str) -> dict:
    """1ソース分の物件リストを Supabase に同期する。"""
    from report_utils import identity_key_str, normalize_listing_name

    summary = {"new": 0, "updated": 0, "removed": 0, "unchanged": 0, "reappeared": 0}
    seen_identity_keys: set[str] = set()

    for item in listings:
        ik = identity_key_str(item)
        if not ik or all(p in ("None", "") for p in ik.split("|")):
            continue
        seen_identity_keys.add(ik)

    if not seen_identity_keys:
        return summary

    # 現在 DB にある active な物件 (このソース + property_type) を取得
    existing_listings = {}
    offset = 0
    while True:
        resp = (client.table("listings")
                .select("id, identity_key, is_active")
                .eq("property_type", property_type)
                .eq("is_active", True)
                .range(offset, offset + 999)
                .execute())
        if not resp.data:
            break
        for row in resp.data:
            existing_listings[row["identity_key"]] = row["id"]
        if len(resp.data) < 1000:
            break
        offset += 1000

    existing_sources = {}
    if existing_listings:
        listing_ids = list(existing_listings.values())
        for i in range(0, len(listing_ids), 100):
            batch_ids = listing_ids[i:i + 100]
            resp = (client.table("listing_sources")
                    .select("id, listing_id, source, price_man, is_active")
                    .eq("source", source)
                    .in_("listing_id", batch_ids)
                    .execute())
            if resp.data:
                for row in resp.data:
                    existing_sources[row["listing_id"]] = row

    # 旧キー(6要素)→新キー(7要素)のフォールバックマップ構築
    def _resolve_identity_key(ik: str) -> str:
        """新キーが既存DBに無い場合、旧キーや floor=None 版で既存を検索し、あれば更新する。"""
        if ik in existing_listings:
            return ik
        parts = ik.split("|")
        if len(parts) == 7:
            # floor=None 版で検索
            fallback = "|".join(parts[:6] + ["None"])
            if fallback in existing_listings:
                lid = existing_listings.pop(fallback)
                client.table("listings").update({"identity_key": ik}).eq("id", lid).execute()
                existing_listings[ik] = lid
                return ik
            # 旧6要素版で検索
            legacy = "|".join(parts[:6])
            if legacy in existing_listings:
                lid = existing_listings.pop(legacy)
                client.table("listings").update({"identity_key": ik}).eq("id", lid).execute()
                existing_listings[ik] = lid
                return ik
            # prefix一致: 同じ6要素prefixで異なるfloor値を持つ旧行を検索
            prefix = "|".join(parts[:6]) + "|"
            for existing_ik in list(existing_listings.keys()):
                if existing_ik.startswith(prefix) or existing_ik == legacy:
                    lid = existing_listings.pop(existing_ik)
                    client.table("listings").update({"identity_key": ik}).eq("id", lid).execute()
                    existing_listings[ik] = lid
                    return ik
        return ik

    # 物件を1件ずつ処理
    for item in listings:
        ik = identity_key_str(item)
        if not ik or all(p in ("None", "") for p in ik.split("|")):
            continue
        ik = _resolve_identity_key(ik)

        normalized_name = normalize_listing_name(item.get("name") or "")
        listing_row = {
            "identity_key": ik,
            "name": item.get("name", ""),
            "normalized_name": normalized_name,
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
            "property_type": property_type,
            "developer_name": item.get("developer_name"),
            "developer_brokerage": item.get("developer_brokerage"),
            "list_ward_roman": item.get("list_ward_roman"),
            "delivery_date": item.get("delivery_date"),
            "duplicate_count": item.get("duplicate_count", 1),
            "latitude": item.get("latitude"),
            "longitude": item.get("longitude"),
            "feature_tags": item.get("feature_tags"),
            "is_active": True,
            "is_new": item.get("is_new", False),
            "is_new_building": item.get("is_new_building", False),
            "first_seen_at": item.get("first_seen_at"),
        }
        # None 値を除去 (Supabase は NULL として扱う)
        listing_row = {k: v for k, v in listing_row.items() if v is not None}

        # listings テーブルに upsert
        resp = (client.table("listings")
                .upsert(listing_row, on_conflict="identity_key")
                .execute())
        if not resp.data:
            continue
        listing_id = resp.data[0]["id"]

        # listing_sources テーブルに upsert
        source_row = {
            "listing_id": listing_id,
            "source": source,
            "url": item.get("url", ""),
            "price_man": item.get("price_man"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "listing_agent": item.get("listing_agent"),
            "is_motodzuke": item.get("is_motodzuke"),
            "last_seen_at": _now_iso(),
            "is_active": True,
        }
        source_row = {k: v for k, v in source_row.items() if v is not None}

        # 価格変動検出
        existing_src = existing_sources.get(listing_id)
        new_price = item.get("price_man")
        price_changed = False
        if existing_src and existing_src.get("is_active") and new_price is not None:
            old_price = existing_src.get("price_man")
            if old_price is not None and old_price != new_price:
                client.table("price_history").insert({
                    "listing_id": listing_id,
                    "source": source,
                    "price_man": new_price,
                }).execute()
                client.table("listing_events").insert({
                    "listing_id": listing_id,
                    "source": source,
                    "event_type": "price_changed",
                    "old_value": str(old_price),
                    "new_value": str(new_price),
                }).execute()
                summary["updated"] += 1
                price_changed = True

        # source upsert
        (client.table("listing_sources")
         .upsert(source_row, on_conflict="listing_id,source")
         .execute())

        if price_changed:
            pass
        elif ik not in existing_listings:
            if existing_src and not existing_src.get("is_active"):
                client.table("listing_events").insert({
                    "listing_id": listing_id,
                    "source": source,
                    "event_type": "reappeared",
                }).execute()
                summary["reappeared"] += 1
            else:
                client.table("listing_events").insert({
                    "listing_id": listing_id,
                    "source": source,
                    "event_type": "appeared",
                }).execute()
                summary["new"] += 1
        elif listing_id not in existing_sources:
            client.table("listing_events").insert({
                "listing_id": listing_id,
                "source": source,
                "event_type": "appeared",
            }).execute()
            summary["new"] += 1
        else:
            summary["unchanged"] += 1

    # このソースの active な物件のうち、今回バッチに無かったものを inactive に
    for ik, listing_id in existing_listings.items():
        if ik not in seen_identity_keys and listing_id in existing_sources:
            src_row = existing_sources[listing_id]
            if src_row.get("is_active"):
                (client.table("listing_sources")
                 .update({"is_active": False, "last_seen_at": _now_iso()})
                 .eq("id", src_row["id"])
                 .execute())
                # 全ソースが inactive なら listing も inactive に
                active_count = (client.table("listing_sources")
                                .select("id", count="exact")
                                .eq("listing_id", listing_id)
                                .eq("is_active", True)
                                .execute())
                if active_count.count == 0:
                    (client.table("listings")
                     .update({"is_active": False})
                     .eq("id", listing_id)
                     .execute())
                client.table("listing_events").insert({
                    "listing_id": listing_id,
                    "source": source,
                    "event_type": "removed",
                }).execute()
                summary["removed"] += 1

    return summary


def _sync_enrichments(client, listings: list[dict]) -> int:
    """エンリッチメントデータを enrichments テーブルに同期する。"""
    from report_utils import identity_key_str

    enrichment_fields = [
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
    ]

    count = 0
    batch_map: dict[int, dict] = {}

    # identity_key → listing_id のマッピングをバッチ取得
    ik_to_id: dict[str, int] = {}
    all_iks = list({identity_key_str(item) for item in listings if identity_key_str(item)})
    for i in range(0, len(all_iks), 100):
        chunk = all_iks[i:i + 100]
        resp = (client.table("listings")
                .select("id, identity_key")
                .in_("identity_key", chunk)
                .execute())
        if resp.data:
            for row in resp.data:
                ik_to_id[row["identity_key"]] = row["id"]

    for item in listings:
        ik = identity_key_str(item)
        if not ik:
            continue

        has_enrichment = any(item.get(f) is not None for f in enrichment_fields)
        if not has_enrichment:
            continue

        listing_id = ik_to_id.get(ik)
        if not listing_id:
            continue

        enrichment_row = {"listing_id": listing_id}
        for field in enrichment_fields:
            val = item.get(field)
            if val is not None:
                enrichment_row[field] = val

        # 同一 listing_id は後勝ちでマージ（重複排除）
        if listing_id in batch_map:
            batch_map[listing_id].update(enrichment_row)
        else:
            batch_map[listing_id] = enrichment_row

    batch = list(batch_map.values())
    count = _batch_upsert(client, "enrichments", batch, "listing_id")
    return count


def sync_to_supabase(output_dir: str) -> None:
    """メインエントリ: latest.json / latest_shinchiku.json を Supabase に同期する。"""
    client = get_client()
    if client is None:
        logger.info("Supabase クライアント未初期化: 同期スキップ")
        return

    output_path = Path(output_dir)

    # 中古
    chuko_path = output_path / "latest.json"
    chuko = _load_json(str(chuko_path))
    if chuko:
        sources_in_batch: dict[str, list[dict]] = {}
        for item in chuko:
            src = item.get("source", "suumo")
            sources_in_batch.setdefault(src, []).append(item)

        for source, items in sources_in_batch.items():
            summary = _sync_source_listings(client, items, source, "chuko")
            logger.info(
                "[supabase] %s(中古): new=%d updated=%d removed=%d unchanged=%d reappeared=%d",
                source, summary["new"], summary["updated"], summary["removed"],
                summary["unchanged"], summary["reappeared"],
            )

        enriched = _sync_enrichments(client, chuko)
        logger.info("[supabase] enrichments(中古): %d 件同期", enriched)
    else:
        logger.info("[supabase] latest.json が空（スキップ）")

    # 新築
    shinchiku_path = output_path / "latest_shinchiku.json"
    shinchiku = _load_json(str(shinchiku_path))
    if shinchiku:
        sources_in_batch: dict[str, list[dict]] = {}
        for item in shinchiku:
            src = item.get("source", "suumo")
            sources_in_batch.setdefault(src, []).append(item)

        for source, items in sources_in_batch.items():
            summary = _sync_source_listings(client, items, source, "shinchiku")
            logger.info(
                "[supabase] %s(新築): new=%d updated=%d removed=%d unchanged=%d reappeared=%d",
                source, summary["new"], summary["updated"], summary["removed"],
                summary["unchanged"], summary["reappeared"],
            )

        enriched = _sync_enrichments(client, shinchiku)
        logger.info("[supabase] enrichments(新築): %d 件同期", enriched)
    else:
        logger.info("[supabase] latest_shinchiku.json が空（スキップ）")

    # 整合性検証: JSON件数 vs Supabase is_active=true 件数
    for pt, items in [("chuko", chuko), ("shinchiku", shinchiku)]:
        if not items:
            continue
        json_count = len(items)
        db_resp = (client.table("listings")
                   .select("id", count="exact")
                   .eq("property_type", pt)
                   .eq("is_active", True)
                   .execute())
        db_count = db_resp.count or 0
        if abs(json_count - db_count) > json_count * 0.1:
            logger.warning(
                "[supabase] 整合性警告: JSON=%d, Supabase=%d (property_type=%s, 乖離%.0f%%)",
                json_count, db_count, pt, abs(json_count - db_count) / json_count * 100,
            )
        else:
            logger.info("[supabase] 整合性OK: JSON=%d, Supabase=%d (%s)", json_count, db_count, pt)

    logger.info("[supabase] 同期完了")
