"""Supabase への物件データ同期モジュール。

既存の db.py (SQLite) と同等のロジックで、Supabase (Postgres) に
物件・ソース・価格履歴・イベントを書き込む。

メインエントリ: sync_to_supabase(output_dir)
"""

from __future__ import annotations

import json
import logging
import math
import os
import sys
from dataclasses import dataclass, field
from datetime import datetime, timezone, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from supabase_client import get_client

logger = logging.getLogger(__name__)

JST = timezone(timedelta(hours=9))
BATCH_SIZE = 500


MAX_STRING_BYTES = 10_000


def _sanitize_value(obj: object) -> object:
    """Recursively sanitize values for PostgreSQL/PostgREST compatibility."""
    if isinstance(obj, float):
        if math.isnan(obj) or math.isinf(obj):
            return None
        return obj
    if isinstance(obj, str):
        if obj.strip().lower() in ("nan", "infinity", "-infinity", "inf", "-inf"):
            return None
        s = obj.replace("\x00", "")
        s = s.encode("utf-8", errors="surrogatepass").decode("utf-8", errors="replace")
        if s and s[0] in ("{", "["):
            try:
                parsed = json.loads(s)
                sanitized = _sanitize_value(parsed)
                s = json.dumps(sanitized, ensure_ascii=False, allow_nan=False)
            except (json.JSONDecodeError, ValueError):
                pass
        if len(s.encode("utf-8")) > MAX_STRING_BYTES:
            encoded = s.encode("utf-8")[:MAX_STRING_BYTES]
            s = encoded.decode("utf-8", errors="ignore")
        return s
    if isinstance(obj, dict):
        return {k: _sanitize_value(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize_value(item) for item in obj]
    return obj


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
    """バッチ upsert。BATCH_SIZE ごとに分割して送信。失敗バッチは1行ずつリトライ。"""
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        batch = [_sanitize_value(row) for row in rows[i:i + BATCH_SIZE]]
        try:
            resp = (client.table(table)
                    .upsert(batch, on_conflict=on_conflict, returning="minimal",
                            count="exact")
                    .execute())
            total += resp.count if resp.count else len(batch)
        except Exception as e:
            logger.warning("[supabase] バッチ upsert 失敗 (%s, %d行): %s — 1行ずつリトライ",
                           table, len(batch), e)
            for row in batch:
                try:
                    (client.table(table)
                     .upsert(row, on_conflict=on_conflict, returning="minimal")
                     .execute())
                    total += 1
                except Exception as row_err:
                    logger.error("[supabase] 行 upsert 失敗 (%s): %s — row_keys=%s",
                                 table, row_err,
                                 list(row.keys())[:5])
    return total


def _group_rows_by_keys(rows: list[dict]) -> list[list[dict]]:
    """行をキー集合ごとにグループ化する。

    PostgREST のバッチ insert/upsert は1リクエスト内の全行が同じキー集合で
    ある必要がある（None キーを除去した行は行ごとにキーが異なりうる）。
    """
    groups: dict[tuple, list[dict]] = {}
    for row in rows:
        groups.setdefault(tuple(sorted(row.keys())), []).append(row)
    return list(groups.values())


def _grouped_batch_upsert(client, table: str, rows: list[dict], on_conflict: str) -> int:
    """キー集合ごとにグループ化してバッチ upsert する。失敗グループは1行ずつリトライ。"""
    total = 0
    for group in _group_rows_by_keys(rows):
        for i in range(0, len(group), BATCH_SIZE):
            batch = group[i:i + BATCH_SIZE]
            try:
                (client.table(table)
                 .upsert(batch, on_conflict=on_conflict, returning="minimal")
                 .execute())
                total += len(batch)
            except Exception as e:
                logger.warning("[supabase] バッチ upsert 失敗 (%s, %d行): %s — 1行ずつリトライ",
                               table, len(batch), e)
                for row in batch:
                    try:
                        (client.table(table)
                         .upsert(row, on_conflict=on_conflict, returning="minimal")
                         .execute())
                        total += 1
                    except Exception as row_err:
                        logger.error("[supabase] 行 upsert 失敗 (%s): %s", table, row_err)
    return total


def _grouped_batch_insert(client, table: str, rows: list[dict]) -> int:
    """キー集合ごとにグループ化してバッチ insert する。失敗グループは1行ずつリトライ。"""
    total = 0
    for group in _group_rows_by_keys(rows):
        for i in range(0, len(group), BATCH_SIZE):
            batch = group[i:i + BATCH_SIZE]
            try:
                client.table(table).insert(batch, returning="minimal").execute()
                total += len(batch)
            except Exception as e:
                logger.warning("[supabase] バッチ insert 失敗 (%s, %d行): %s — 1行ずつリトライ",
                               table, len(batch), e)
                for row in batch:
                    try:
                        client.table(table).insert(row, returning="minimal").execute()
                        total += 1
                    except Exception as row_err:
                        logger.error("[supabase] 行 insert 失敗 (%s): %s", table, row_err)
    return total


@dataclass
class SourceSyncPlan:
    """_plan_source_sync の出力。バッチ書き込みする行と件数集計。"""
    source_rows: list[dict] = field(default_factory=list)
    price_history_rows: list[dict] = field(default_factory=list)
    event_rows: list[dict] = field(default_factory=list)
    summary: dict = field(default_factory=lambda: {
        "new": 0, "updated": 0, "removed": 0, "unchanged": 0, "reappeared": 0,
    })


def _plan_source_sync(
    items: list[tuple[dict, str, int]],
    existing_listings: dict[str, int],
    existing_sources: dict[int, dict],
    source: str,
) -> SourceSyncPlan:
    """同期の計画フェーズ（純粋関数・ネットワーク I/O なし）。

    items: (物件dict, identity_key, listing_id) のリスト。
    旧実装は物件1件ごとに upsert + SELECT + insert を逐次実行しており
    N 件で最大 4N 回の HTTP コールが発生していた。計画と実行を分離し、
    実行側はテーブルごとのバッチ書き込みにする。
    """
    plan = SourceSyncPlan()
    now = _now_iso()
    seen_source_keys: set[tuple[int, str]] = set()

    for item, ik, listing_id in items:
        # 同一バッチ内の同一 (listing_id, source) はバッチ upsert がエラーに
        # なるため最初の1件のみ処理する
        if (listing_id, source) in seen_source_keys:
            continue
        seen_source_keys.add((listing_id, source))

        source_row = {
            "listing_id": listing_id,
            "source": source,
            "url": item.get("url", ""),
            "price_man": item.get("price_man"),
            "management_fee": item.get("management_fee"),
            "repair_reserve_fund": item.get("repair_reserve_fund"),
            "listing_agent": item.get("listing_agent"),
            "is_motodzuke": item.get("is_motodzuke"),
            "price_max_man": item.get("price_max_man"),
            "last_seen_at": now,
            "is_active": True,
            "consecutive_misses": 0,
        }
        source_row = {k: v for k, v in _sanitize_value(source_row).items() if v is not None}
        plan.source_rows.append(source_row)

        existing_src = existing_sources.get(listing_id)
        new_price = item.get("price_man")
        price_changed = False
        if existing_src and existing_src.get("is_active") and new_price is not None:
            old_price = existing_src.get("price_man")
            if old_price is not None and old_price != new_price:
                plan.price_history_rows.append({
                    "listing_id": listing_id, "source": source, "price_man": new_price,
                })
                plan.event_rows.append({
                    "listing_id": listing_id, "source": source,
                    "event_type": "price_changed",
                    "old_value": str(old_price), "new_value": str(new_price),
                })
                plan.summary["updated"] += 1
                price_changed = True

        if price_changed:
            continue
        if ik not in existing_listings:
            if existing_src and not existing_src.get("is_active"):
                plan.event_rows.append({
                    "listing_id": listing_id, "source": source, "event_type": "reappeared",
                })
                plan.summary["reappeared"] += 1
            else:
                plan.event_rows.append({
                    "listing_id": listing_id, "source": source, "event_type": "appeared",
                })
                plan.summary["new"] += 1
            if new_price is not None:
                plan.price_history_rows.append({
                    "listing_id": listing_id, "source": source, "price_man": new_price,
                })
        elif listing_id not in existing_sources:
            plan.event_rows.append({
                "listing_id": listing_id, "source": source, "event_type": "appeared",
            })
            plan.summary["new"] += 1
            if new_price is not None:
                plan.price_history_rows.append({
                    "listing_id": listing_id, "source": source, "price_man": new_price,
                })
        else:
            plan.summary["unchanged"] += 1

    return plan


@dataclass
class GracePeriodPlan:
    """_plan_grace_period の出力。掲載終了処理のバッチ計画。"""
    deactivate_source_ids: list[int] = field(default_factory=list)
    deactivate_listing_candidates: list[int] = field(default_factory=list)
    # consecutive_misses の新しい値 → 対象 listing_sources.id のリスト
    miss_increment_groups: dict[int, list[int]] = field(default_factory=dict)
    event_rows: list[dict] = field(default_factory=list)
    removed_count: int = 0
    grace_pending: int = 0


def _plan_grace_period(
    existing_listings: dict[str, int],
    seen_identity_keys: set[str],
    existing_sources: dict[int, dict],
    grace_threshold: int,
    source: str,
) -> GracePeriodPlan:
    """掲載終了判定の計画フェーズ（純粋関数）。

    旧実装は欠落物件 K 件ごとに最大4回の HTTP コール（update + count +
    update + insert）を逐次実行していた。同じ値の update はまとめて
    `.in_()` で1回にできるため、計画と実行を分離する。
    """
    plan = GracePeriodPlan()
    for ik, listing_id in existing_listings.items():
        if ik in seen_identity_keys:
            continue
        src_row = existing_sources.get(listing_id)
        if not src_row or not src_row.get("is_active"):
            continue

        new_misses = (src_row.get("consecutive_misses") or 0) + 1
        if new_misses >= grace_threshold:
            plan.deactivate_source_ids.append(src_row["id"])
            plan.deactivate_listing_candidates.append(listing_id)
            plan.event_rows.append({
                "listing_id": listing_id, "source": source, "event_type": "removed",
            })
            plan.removed_count += 1
        else:
            plan.miss_increment_groups.setdefault(new_misses, []).append(src_row["id"])
            plan.grace_pending += 1
    return plan


def _delete_duplicate_listing(client, listing_id: int) -> None:
    """重複物件を listings への単一 DELETE で削除する。

    子テーブル（listing_sources / enrichments / price_history / listing_events）は
    すべて ON DELETE CASCADE（migration 001）のため、1リクエスト = 1トランザクションで
    原子的に削除される。子テーブルを個別に DELETE すると途中失敗時に
    孤児レコードが残るため、必ずこの関数を使うこと。
    失敗時は例外を伝播させる（部分削除が発生しないため安全に再試行できる）。
    """
    client.table("listings").delete(returning="minimal").eq("id", listing_id).execute()


def _sync_source_listings(client, listings: list[dict], source: str, property_type: str) -> dict:
    """1ソース分の物件リストを Supabase に同期する。"""
    from report_utils import identity_key_str, normalize_listing_name, _normalize_address_for_key

    summary = {"new": 0, "updated": 0, "removed": 0, "unchanged": 0, "reappeared": 0}
    seen_identity_keys: set[str] = set()

    for item in listings:
        ik = identity_key_str(item)
        if not ik or all(p in ("None", "") for p in ik.split("|")):
            continue
        seen_identity_keys.add(ik)

    if not seen_identity_keys:
        return summary

    # 現在 DB にある物件 (このproperty_type) を全件取得（active/inactive 両方）
    # inactive も取得しないとフォールバック検索で重複が発生する
    all_db_listings: dict[str, tuple[int, bool]] = {}  # identity_key → (id, is_active)
    existing_listings: dict[str, int] = {}  # active のみ: identity_key → id
    offset = 0
    while True:
        resp = (client.table("listings")
                .select("id, identity_key, is_active")
                .eq("property_type", property_type)
                .range(offset, offset + 999)
                .execute())
        if not resp.data:
            break
        for row in resp.data:
            ik = row["identity_key"]
            all_db_listings[ik] = (row["id"], row["is_active"])
            if row["is_active"]:
                existing_listings[ik] = row["id"]
        if len(resp.data) < 1000:
            break
        offset += 1000

    existing_sources = {}
    all_listing_ids = [lid for lid, _ in all_db_listings.values()]
    for i in range(0, len(all_listing_ids), 100):
        batch_ids = all_listing_ids[i:i + 100]
        resp = (client.table("listing_sources")
                .select("id, listing_id, source, price_man, is_active, consecutive_misses")
                .eq("source", source)
                .in_("listing_id", batch_ids)
                .execute())
        if resp.data:
            for row in resp.data:
                existing_sources[row["listing_id"]] = row

    # 重複削除済み ID を記録（同一物件の旧レコードを削除した際に再処理を防ぐ）
    _deleted_ids: set[int] = set()

    def _resolve_identity_key(ik: str) -> str:
        """新キーが既存DBに無い場合、旧キーや floor=None 版で既存を検索し、あれば更新する。
        active/inactive 両方を検索し、重複レコードがあれば1つに統合する。
        新形式: 6要素 (name|layout|area|address|built_year|floor)
        旧形式: 7要素 (name|layout|area|address|built_year|station_name|floor)"""
        if ik in existing_listings:
            return ik
        # inactive でも完全一致があればそれを再利用（active に戻す）
        if ik in all_db_listings:
            lid, was_active = all_db_listings[ik]
            if lid not in _deleted_ids:
                existing_listings[ik] = lid
                return ik

        parts = ik.split("|")
        if len(parts) != 6:
            return ik

        # 新形式: name|layout|area|address|built_year|floor
        new_prefix_5 = "|".join(parts[:5])
        new_floor = parts[5]

        def _normalize_prefix(p5: str) -> str:
            """住所部分を正規化して比較用プレフィックスを生成。
            旧レコードの東京都prefix/丁目suffix/番地差異を吸収する。"""
            segs = p5.split("|")
            if len(segs) >= 4:
                segs[3] = _normalize_address_for_key(segs[3])
            return "|".join(segs)

        norm_new = _normalize_prefix(new_prefix_5)

        # フォールバック候補を収集（active/inactive 両方から）
        candidates: list[tuple[str, int, bool]] = []  # (old_key, id, is_active)

        for db_ik, (lid, is_active) in list(all_db_listings.items()):
            if lid in _deleted_ids:
                continue
            old_parts = db_ik.split("|")
            if len(old_parts) == 7:
                # 旧7要素: name|layout|area|address|built_year|station_name|floor
                norm_old = _normalize_prefix("|".join(old_parts[:5]))
                if norm_old == norm_new and old_parts[6] == new_floor:
                    candidates.append((db_ik, lid, is_active))
            elif len(old_parts) == 6 and db_ik != ik:
                # 同じ6要素だが floor 違い or station入り旧形式
                norm_old = _normalize_prefix("|".join(old_parts[:5]))
                if norm_old == norm_new:
                    candidates.append((db_ik, lid, is_active))

        if not candidates:
            return ik

        # 最優先: active なレコードを再利用
        # 複数ある場合は id が最も大きい（最新）ものを選択
        candidates.sort(key=lambda c: (c[2], c[1]), reverse=True)
        best_key, best_id, _ = candidates[0]

        # best を新しい identity_key に更新
        (client.table("listings")
         .update({"identity_key": ik}, returning="minimal")
         .eq("id", best_id).execute())
        existing_listings.pop(best_key, None)
        existing_listings[ik] = best_id
        all_db_listings.pop(best_key, None)
        all_db_listings[ik] = (best_id, True)

        # 残りの重複レコードを削除（CASCADE で子テーブルごと原子的に削除される）
        for old_key, old_id, _ in candidates[1:]:
            if old_id == best_id:
                continue
            _delete_duplicate_listing(client, old_id)
            _deleted_ids.add(old_id)
            existing_listings.pop(old_key, None)
            all_db_listings.pop(old_key, None)

        return ik

    # --- フェーズ1: 行構築（identity_key 解決はフォールバック時のみネットワーク）---
    resolved_items: list[tuple[dict, str]] = []
    listing_rows_by_ik: dict[str, dict] = {}  # バッチ upsert は同一キー重複不可のため ik ごとに1行
    for item in listings:
        if item.get("price_man") is None:
            logger.debug("price_man=None のため除外: source=%s url=%s",
                         item.get("source"), item.get("url"))
            continue
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
            "first_seen_at": item.get("first_seen_at"),
            "first_seen_source": item.get("first_seen_source"),
            "geocode_confidence": item.get("geocode_confidence"),
            "geocode_fixed": item.get("geocode_fixed"),
            "alt_urls": item.get("alt_urls"),
        }
        listing_row["is_new"] = bool(item.get("is_new", False))
        listing_row["is_new_building"] = bool(item.get("is_new_building", False))

        REAL_COLUMNS = {"area_m2", "area_max_m2", "balcony_area_m2", "latitude", "longitude"}
        listing_row = {
            k: v
            for k, v in _sanitize_value(listing_row).items()
            if v is not None or k in REAL_COLUMNS
        }
        listing_rows_by_ik[ik] = listing_row
        resolved_items.append((item, ik))

    # --- フェーズ2: listings 一括 upsert（representation で id を直接取得）---
    # 旧実装は1件ごとに upsert + SELECT（2N リクエスト）だった。
    # returning="representation" なら upsert レスポンスから id が取れる
    ik_to_id: dict[str, int] = {}
    for group in _group_rows_by_keys(list(listing_rows_by_ik.values())):
        for i in range(0, len(group), BATCH_SIZE):
            batch = group[i:i + BATCH_SIZE]
            try:
                resp = (client.table("listings")
                        .upsert(batch, on_conflict="identity_key", returning="representation")
                        .execute())
                for r in (resp.data or []):
                    ik_to_id[r["identity_key"]] = r["id"]
            except Exception as e:
                logger.warning("[supabase] listings バッチ upsert 失敗 (%d行): %s — 1行ずつリトライ",
                               len(batch), e)
                for row in batch:
                    try:
                        resp = (client.table("listings")
                                .upsert(row, on_conflict="identity_key", returning="representation")
                                .execute())
                        for r in (resp.data or []):
                            ik_to_id[r["identity_key"]] = r["id"]
                    except Exception as row_err:
                        logger.error("[supabase] listings 行 upsert 失敗 (ik=%s): %s",
                                     row.get("identity_key"), row_err)

    # representation で id が返らなかった分の防御的フォールバック
    missing_iks = [ik for ik in listing_rows_by_ik if ik not in ik_to_id]
    for i in range(0, len(missing_iks), 100):
        batch_iks = missing_iks[i:i + 100]
        resp = (client.table("listings")
                .select("id, identity_key")
                .in_("identity_key", batch_iks)
                .execute())
        for r in (resp.data or []):
            ik_to_id[r["identity_key"]] = r["id"]

    # --- フェーズ3: 計画（純粋関数）---
    planned_items = [(item, ik, ik_to_id[ik]) for item, ik in resolved_items if ik in ik_to_id]
    skipped = len(resolved_items) - len(planned_items)
    if skipped:
        logger.warning("[supabase] id 解決できず %d 件をスキップ", skipped)
    plan = _plan_source_sync(planned_items, existing_listings, existing_sources, source)
    for key in summary:
        summary[key] += plan.summary[key]

    # --- フェーズ4: バッチ書き込み ---
    _grouped_batch_upsert(client, "listing_sources", plan.source_rows,
                          on_conflict="listing_id,source")
    _grouped_batch_insert(client, "price_history", plan.price_history_rows)
    _grouped_batch_insert(client, "listing_events", plan.event_rows)

    # --- 掲載終了（grace period）: 計画 → バッチ実行 ---
    grace_threshold = int(os.environ.get("GRACE_PERIOD_RUNS", "2"))
    gplan = _plan_grace_period(
        existing_listings, seen_identity_keys, existing_sources, grace_threshold, source,
    )

    if gplan.deactivate_source_ids:
        for i in range(0, len(gplan.deactivate_source_ids), 100):
            batch_ids = gplan.deactivate_source_ids[i:i + 100]
            (client.table("listing_sources")
             .update({"is_active": False, "last_seen_at": _now_iso(),
                      "consecutive_misses": 0},
                     returning="minimal")
             .in_("id", batch_ids)
             .execute())

        # deactivate 後に他ソースが active な listing を除外して listings を inactive 化
        still_active: set[int] = set()
        candidates = gplan.deactivate_listing_candidates
        for i in range(0, len(candidates), 100):
            batch_ids = candidates[i:i + 100]
            resp = (client.table("listing_sources")
                    .select("listing_id")
                    .in_("listing_id", batch_ids)
                    .eq("is_active", True)
                    .execute())
            for r in (resp.data or []):
                still_active.add(r["listing_id"])
        to_deactivate = [lid for lid in candidates if lid not in still_active]
        for i in range(0, len(to_deactivate), 100):
            batch_ids = to_deactivate[i:i + 100]
            (client.table("listings")
             .update({"is_active": False}, returning="minimal")
             .in_("id", batch_ids)
             .execute())

    # 同じ値になる consecutive_misses 更新は .in_() でまとめる
    for new_misses, src_ids in gplan.miss_increment_groups.items():
        for i in range(0, len(src_ids), 100):
            batch_ids = src_ids[i:i + 100]
            (client.table("listing_sources")
             .update({"consecutive_misses": new_misses}, returning="minimal")
             .in_("id", batch_ids)
             .execute())

    _grouped_batch_insert(client, "listing_events", gplan.event_rows)
    summary["removed"] += gplan.removed_count

    if gplan.grace_pending:
        logger.info("grace_pending=%d listings deferred from removal (source=%s)",
                    gplan.grace_pending, source)
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

    count = 0
    batch_map: dict[int, dict] = {}

    # identity_key → listing_id のマッピングをバッチ取得
    ik_to_id: dict[str, int] = {}
    all_iks = list({identity_key_str(item) for item in listings if identity_key_str(item)})
    # identity_key は日本語を含むためURL-encode後1件150B超 → 100件で20KB超えPostgREST制限
    for i in range(0, len(all_iks), 20):
        chunk = all_iks[i:i + 20]
        try:
            resp = (client.table("listings")
                    .select("id, identity_key")
                    .in_("identity_key", chunk)
                    .execute())
            if resp.data:
                for row in resp.data:
                    ik_to_id[row["identity_key"]] = row["id"]
        except Exception as e:
            logger.error("[supabase] listing_id 解決エラー (chunk %d): %s", i, e)
            for ik in chunk:
                try:
                    resp = (client.table("listings")
                            .select("id, identity_key")
                            .eq("identity_key", ik)
                            .execute())
                    if resp.data:
                        ik_to_id[resp.data[0]["identity_key"]] = resp.data[0]["id"]
                except Exception as row_err:
                    logger.debug("[supabase] per-row fallback 失敗 (ik=%s): %s", ik[:40], row_err)

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


def _sync_transactions(client, tx_path: str) -> int:
    """transactions.json を Supabase の transactions / building_groups / transaction_metadata に同期。"""
    p = Path(tx_path)
    if not p.exists() or p.stat().st_size == 0:
        return 0
    with open(p) as f:
        data = json.load(f)
    if not isinstance(data, dict):
        return 0
    transactions = data.get("transactions", [])
    building_groups = data.get("building_groups", [])
    metadata = data.get("metadata")

    tx_count = 0
    if transactions:
        tx_rows = []
        for tx in transactions:
            row = {
                "id": tx["id"],
                "prefecture": tx.get("prefecture", ""),
                "ward": tx.get("ward", ""),
                "district": tx.get("district", ""),
                "district_code": tx.get("district_code", ""),
                "price_man": tx.get("price_man"),
                "area_m2": tx.get("area_m2"),
                "m2_price": tx.get("m2_price"),
                "layout": tx.get("layout", ""),
                "built_year": tx.get("built_year"),
                "structure": tx.get("structure", ""),
                "trade_period": tx.get("trade_period", ""),
                "nearest_station": tx.get("nearest_station"),
                "estimated_walk_min": tx.get("estimated_walk_min"),
                "latitude": tx.get("latitude"),
                "longitude": tx.get("longitude"),
                "building_group_id": tx.get("building_group_id"),
                "estimated_building_name": tx.get("estimated_building_name"),
            }
            tx_rows.append({k: v for k, v in row.items() if v is not None})
        tx_count = _batch_upsert(client, "transactions", tx_rows, "id")

    if building_groups:
        bg_rows = []
        for bg in building_groups:
            row = {
                "group_id": bg["group_id"],
                "prefecture": bg.get("prefecture", ""),
                "ward": bg.get("ward", ""),
                "district": bg.get("district", ""),
                "built_year": bg.get("built_year"),
                "structure": bg.get("structure", ""),
                "nearest_station": bg.get("nearest_station"),
                "estimated_walk_min": bg.get("estimated_walk_min"),
                "latitude": bg.get("latitude"),
                "longitude": bg.get("longitude"),
                "transaction_count": bg.get("transaction_count", 0),
                "price_range_man": bg.get("price_range_man"),
                "avg_m2_price": bg.get("avg_m2_price"),
                "periods": bg.get("periods"),
                "latest_period": bg.get("latest_period"),
                "estimated_building_name": bg.get("estimated_building_name"),
            }
            bg_rows.append({k: v for k, v in row.items() if v is not None})
        _batch_upsert(client, "building_groups", bg_rows, "group_id")

    if metadata:
        meta_row = {
            "id": "default",
            "updated_at": metadata.get("updated_at", _now_iso()),
            "periods_covered": metadata.get("periods_covered", []),
            "data_source": metadata.get("data_source", ""),
            "transaction_count": metadata.get("transaction_count", 0),
            "building_group_count": metadata.get("building_group_count", 0),
            "scope": metadata.get("scope", ""),
        }
        (client.table("transaction_metadata")
         .upsert(_sanitize_value(meta_row), on_conflict="id", returning="minimal")
         .execute())

    return tx_count


def sync_to_supabase(output_dir: str, *, skip_enrichments: bool = False) -> None:
    """メインエントリ: latest.json / latest_shinchiku.json を Supabase に同期する。

    skip_enrichments=True の場合、listings/sources/events のみ同期し
    enrichments テーブルへの書き込みをスキップする（dual-write 運用時用）。
    """
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
            try:
                summary = _sync_source_listings(client, items, source, "chuko")
                logger.info(
                    "[supabase] %s(中古): new=%d updated=%d removed=%d unchanged=%d reappeared=%d",
                    source, summary["new"], summary["updated"], summary["removed"],
                    summary["unchanged"], summary["reappeared"],
                )
            except Exception as e:
                logger.error("[supabase] %s(中古) listings 同期失敗: %s", source, e)

        if skip_enrichments:
            logger.info("[supabase] enrichments(中古): スキップ（dual-write モード）")
        else:
            try:
                enriched = _sync_enrichments(client, chuko)
                logger.info("[supabase] enrichments(中古): %d 件同期", enriched)
            except Exception as e:
                logger.error("[supabase] enrichments(中古) 同期失敗: %s", e)
    else:
        logger.info("[supabase] latest.json が空（スキップ）")

    # 整合性検証: JSON件数 vs Supabase is_active=true 件数
    for pt, items in [("chuko", chuko)]:
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

    # トランザクション同期
    tx_path = output_path / "transactions.json"
    if tx_path.exists():
        try:
            tx_count = _sync_transactions(client, str(tx_path))
            logger.info("[supabase] transactions: %d 件同期", tx_count)
        except Exception as e:
            logger.error("[supabase] transactions 同期失敗: %s", e)

    # 基準外物件の除外を適用（scraping_config テーブルの設定値を参照）
    try:
        resp = client.rpc("apply_spec_exclusions").execute()
        if resp.data:
            row = resp.data[0] if isinstance(resp.data, list) else resp.data
            excluded = row.get("excluded_count", 0)
            restored = row.get("restored_count", 0)
            if excluded or restored:
                logger.info("[supabase] spec_exclusions: %d件除外, %d件復活", excluded, restored)
    except Exception as e:
        logger.warning("[supabase] apply_spec_exclusions 失敗: %s", e)

    logger.info("[supabase] 同期完了")
