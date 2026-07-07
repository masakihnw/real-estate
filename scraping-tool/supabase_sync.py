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

import scraper_metrics
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


def _resolve_merged_redirect(
    ik: str,
    all_db_listings: dict[str, tuple[int, bool, int | None]],
    max_depth: int = 5,
) -> int | None:
    """identity_key が統合済みレコード（merged_into 付き tombstone）に一致する場合、
    統合先 listing の id を返す。未統合なら None。

    重複統合された物件のページがサイトに掲載され続ける限り、スクレイパーは
    同じ identity_key を再計算する。tombstone を再アクティブ化する代わりに
    統合先へリダイレクトすることで、統合済み物件の蘇生・再作成を防ぐ。
    merged_into チェーン（A→B→C）は max_depth まで辿る。
    """
    entry = all_db_listings.get(ik)
    if not entry or entry[2] is None:
        return None
    by_id = {v[0]: v for v in all_db_listings.values()}
    target = entry[2]
    for _ in range(max_depth):
        nxt = by_id.get(target)
        if not nxt or nxt[2] is None:
            # 非tombstone に到達 or 統合先がDBに無い（削除済み）→ 最後に解決できた id を返す
            return target
        target = nxt[2]
    return target


def _delete_duplicate_listing(client, listing_id: int) -> None:
    """重複物件を listings への単一 DELETE で削除する。

    子テーブル（listing_sources / enrichments / price_history / listing_events）は
    すべて ON DELETE CASCADE（migration 001）のため、1リクエスト = 1トランザクションで
    原子的に削除される。子テーブルを個別に DELETE すると途中失敗時に
    孤児レコードが残るため、必ずこの関数を使うこと。
    失敗時は例外を伝播させる（部分削除が発生しないため安全に再試行できる）。
    """
    client.table("listings").delete(returning="minimal").eq("id", listing_id).execute()


# --- source+URL 突合レイヤ（純関数）---------------------------------------
# 不変条件: 「同一 (source, url) は同一 listing（中古=同一住戸 / 新築=同一建物）」。
# identity_key（name|layout|area|address|built_year|floor）はパース値のブレに弱く、
# 再スクレイプで面積・築年・名前のいずれかがブレると別キーになり新規INSERTされ、
# 同一URLが複数 listing に増殖する。URL突合をフォールバックの前段に挿入して収束させる。

def _build_url_index(source_rows: list[dict]) -> dict[str, list[int]]:
    """listing_sources 行群から url → [listing_id, ...] の索引を構築する。

    呼び出し元（_sync_source_listings）は1ソース固定なので source はキーに含めない。
    同一URLに複数 listing_id がぶら下がる既存重複も全件収集する。
    url が None/空 の行はスキップ。listing_id は昇順・重複排除。
    """
    index: dict[str, set[int]] = {}
    for row in source_rows:
        url = row.get("url")
        lid = row.get("listing_id")
        if not url or lid is None:
            continue
        index.setdefault(url, set()).add(lid)
    return {url: sorted(ids) for url, ids in index.items()}


def _floor_from_identity_key(ik: str | None) -> int | None:
    """identity_key 文字列の末尾要素（floor_position）を整数で返す。None/不正は None。"""
    if not ik:
        return None
    last = ik.split("|")[-1]
    if last in ("", "None"):
        return None
    try:
        return int(float(last))
    except (ValueError, TypeError):
        return None


def _url_merge_allowed(item_floor: int | None, other_floor: int | None) -> bool:
    """URL突合でのマージ可否。両方に階があり異なる場合のみ不可（別住戸とみなす）。

    片方でも None なら許可（中古=同一住戸/新築=同一建物の前提で収束させる）。
    """
    if item_floor is not None and other_floor is not None:
        return item_floor == other_floor
    return True


def _select_url_survivor(listing_ids: list[int]) -> tuple[int, list[int]]:
    """同一URLにぶら下がる複数 listing_id から survivor を選定する。

    基準: 最小 listing_id（最古 = first_seen / price_history を最大限保全）。
    戻り値: (survivor_id, excess_ids)。
    """
    survivor = min(listing_ids)
    excess = [lid for lid in listing_ids if lid != survivor]
    return survivor, excess


def _is_identity_key_conflict(exc: Exception) -> bool:
    """listings.identity_key の一意制約違反(23505)かどうかを判定する。

    identity_key の付け替え UPDATE で、別レコード（別 property_type / 既統合 tombstone /
    取得後レース）が同じ identity_key を既に保持している場合に Postgres が返す。
    ネットワーク/RLS/想定外の制約違反まで握り潰さないよう、23505 か
    listings_identity_key_key に限定して判定する。
    """
    code = getattr(exc, "code", None)
    if code == "23505":
        return True
    # code 属性が無い例外（素の Exception 等）向けフォールバック。
    # 偶発的な "23505" 文字列の誤検知を避けるため制約名で判定する。
    blob = f"{getattr(exc, 'message', '') or ''} {exc}"
    return "listings_identity_key_key" in blob


def _sync_source_listings(client, listings: list[dict], source: str, property_type: str) -> dict:
    """1ソース分の物件リストを Supabase に同期する。"""
    from report_utils import identity_key_str, normalize_listing_name, _normalize_address_for_key, strip_name_brackets

    summary = {"new": 0, "updated": 0, "removed": 0, "unchanged": 0, "reappeared": 0}
    seen_identity_keys: set[str] = set()

    # フェイルクローズ: 巡回で見えた ik は無条件に「確認済み」へ入れる
    # （price_man 欠落や tombstone 一致の ik も含む。余分な ik が混ざっても
    # 掲載終了判定が保守的になるだけで、誤 deactivate は起きない）
    for item in listings:
        ik = identity_key_str(item)
        if not ik or all(p in ("None", "") for p in ik.split("|")):
            continue
        seen_identity_keys.add(ik)

    if not seen_identity_keys:
        return summary

    # 現在 DB にある物件 (このproperty_type) を全件取得（active/inactive 両方）
    # inactive も取得しないとフォールバック検索で重複が発生する
    # identity_key → (id, is_active, merged_into)
    all_db_listings: dict[str, tuple[int, bool, int | None]] = {}
    existing_listings: dict[str, int] = {}  # active のみ: identity_key → id
    offset = 0
    while True:
        resp = (client.table("listings")
                .select("id, identity_key, is_active, merged_into")
                .eq("property_type", property_type)
                .range(offset, offset + 999)
                .execute())
        if not resp.data:
            break
        for row in resp.data:
            ik = row["identity_key"]
            all_db_listings[ik] = (row["id"], row["is_active"], row.get("merged_into"))
            if row["is_active"]:
                existing_listings[ik] = row["id"]
        if len(resp.data) < 1000:
            break
        offset += 1000

    # 統合先リダイレクト用の逆引き（id → 現在の identity_key）
    id_to_ik: dict[int, str] = {v[0]: k for k, v in all_db_listings.items()}

    existing_sources = {}
    all_listing_ids = [v[0] for v in all_db_listings.values()]
    for i in range(0, len(all_listing_ids), 100):
        batch_ids = all_listing_ids[i:i + 100]
        resp = (client.table("listing_sources")
                .select("id, listing_id, source, url, price_man, is_active, consecutive_misses")
                .eq("source", source)
                .in_("listing_id", batch_ids)
                .execute())
        if resp.data:
            for row in resp.data:
                existing_sources[row["listing_id"]] = row

    # source+URL 突合用の索引（url → [listing_id, ...]）。同一URLの既存重複も収集。
    url_index = _build_url_index(list(existing_sources.values()))

    # 重複削除済み ID を記録（同一物件の旧レコードを削除した際に再処理を防ぐ）
    _deleted_ids: set[int] = set()
    # fuzzy 解決で tombstone のみに一致した場合の統合先通知（1アイテム処理ごとに消費）
    _fuzzy_redirect_target: list[int] = []
    # 同一ランで URL 収束済みの (url → (survivor_id, canonical_ik))。
    # 1スクレイプ内に同一URLが複数 item で出ても survivor の ik を1つに固定し、
    # 別キーでの3本目作成を防ぐ。
    _url_claimed: dict[str, tuple[int, str]] = {}

    def _resolve_conflict_redirect(conflict_ik: str) -> int | None:
        """identity_key 付け替えが一意制約に衝突したとき、その ik を現在保持している
        レコードを DB からグローバルに引き、安全な統合先 active id を返す。

        - 保持者が active（merged_into なし）→ その id（item をそこへ寄せる）。
        - 保持者が tombstone（merged_into あり）→ チェーンを辿って非 tombstone の id。
          tombstone 自体は再アクティブ化しない（migration 046 の不変条件を守る）。
        - 解決不能（保持者消失/循環/欠落）→ None。
        ローカル all_db_listings は property_type で絞られ衝突相手が見えないため DB を引く。
        """
        try:
            resp = (client.table("listings")
                    .select("id, merged_into")
                    .eq("identity_key", conflict_ik).limit(1).execute())
        except Exception as e:
            logger.warning("[supabase] 衝突相手の lookup 失敗 (ik=%s): %s", conflict_ik, e)
            return None
        rows = resp.data or []
        if not rows:
            return None
        cur_id = rows[0]["id"]
        merged = rows[0].get("merged_into")
        seen: set[int] = set()
        for _ in range(6):  # merged_into チェーンの上限ホップ（循環の保険）
            if merged is None:
                return cur_id
            if merged in seen:
                return None
            seen.add(merged)
            r = (client.table("listings")
                 .select("id, merged_into").eq("id", merged).limit(1).execute()).data or []
            if not r:
                return None
            cur_id = r[0]["id"]
            merged = r[0].get("merged_into")
        return None

    def _resolve_identity_key(ik: str) -> str | None:
        """新キーが既存DBに無い場合、旧キーや floor=None 版で既存を検索し、あれば更新する。
        戻り値 None は「identity_key 衝突を安全に解決できず item をスキップすべき」を表す。
        active/inactive 両方を検索し、重複レコードがあれば1つに統合する。
        新形式: 6要素 (name|layout|area|address|built_year|floor)
        旧形式: 7要素 (name|layout|area|address|built_year|station_name|floor)"""
        if ik in existing_listings:
            return ik
        # inactive でも完全一致があればそれを再利用（active に戻す）
        # ※ merged_into 付き tombstone はここに来ない（呼び出し前にリダイレクト済み）
        if ik in all_db_listings:
            lid, _was_active, _merged = all_db_listings[ik]
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
        merged_candidates: list[tuple[str, int, bool]] = []  # tombstone のみの一致

        for db_ik, (lid, is_active, merged) in list(all_db_listings.items()):
            if lid in _deleted_ids:
                continue
            old_parts = db_ik.split("|")
            if len(old_parts) == 7:
                # 旧7要素: name|layout|area|address|built_year|station_name|floor
                norm_old = _normalize_prefix("|".join(old_parts[:5]))
                if norm_old == norm_new and old_parts[6] == new_floor:
                    (merged_candidates if merged is not None else candidates).append(
                        (db_ik, lid, is_active))
            elif len(old_parts) == 6 and db_ik != ik:
                # 同じ6要素だが floor 違い or station入り旧形式
                norm_old = _normalize_prefix("|".join(old_parts[:5]))
                if norm_old == norm_new:
                    (merged_candidates if merged is not None else candidates).append(
                        (db_ik, lid, is_active))

        if not candidates:
            # 一致が統合済み tombstone のみ → 再利用/削除はせず統合先へリダイレクト
            # （除外して新規作成すると3本目の重複が生まれるため）
            if merged_candidates:
                merged_candidates.sort(key=lambda c: (c[2], c[1]), reverse=True)
                target = _resolve_merged_redirect(merged_candidates[0][0], all_db_listings)
                if target is not None:
                    logger.info("[supabase] fuzzy一致が tombstone のみ (ik=%s) — 統合先 id=%d へリダイレクト",
                                ik, target)
                    _fuzzy_redirect_target.append(target)
            return ik

        # 最優先: active なレコードを再利用
        # 複数ある場合は id が最も大きい（最新）ものを選択
        candidates.sort(key=lambda c: (c[2], c[1]), reverse=True)
        best_key, best_id, _ = candidates[0]

        # best を新しい identity_key に更新
        try:
            (client.table("listings")
             .update({"identity_key": ik}, returning="minimal")
             .eq("id", best_id).execute())
        except Exception as e:
            if not _is_identity_key_conflict(e):
                raise
            # ik を別レコード（別 property_type / tombstone / レース）が既に保持。
            # best_id を付け替えず、item を既存保持者へリダイレクトして source 全体の
            # 中断を防ぐ（all-or-nothing 回避）。tombstone は統合先へ解決し再アクティブ化しない。
            # フォールバックで一致した既存 listing(best_key=best_id) を grace period の
            # 掲載終了判定から守る（フェイルクローズ。付け替え失敗を理由に既存を消さない）。
            seen_identity_keys.add(best_key)
            redirect_id = _resolve_conflict_redirect(ik)
            if redirect_id is None:
                # 衝突相手を解決できない（lookup失敗 / dangling / cycle tombstone）。
                # ここで ik を返すとフェーズ2の upsert が衝突先（tombstone を含む）を
                # is_active=True で更新＝蘇生させ得るため、item をスキップする
                # （フェイルクローズ。migration 046 の tombstone 不変条件を守る）。
                logger.warning(
                    "[supabase] identity_key 衝突かつ統合先を解決できず item をスキップ "
                    "(ik=%s, best_id=%d)", ik, best_id)
                return None
            logger.warning(
                "[supabase] identity_key 衝突のため付け替えスキップ "
                "(ik=%s, best_id=%d) — 既存 id=%d へリダイレクト",
                ik, best_id, redirect_id)
            _fuzzy_redirect_target.append(redirect_id)
            return ik
        existing_listings.pop(best_key, None)
        existing_listings[ik] = best_id
        all_db_listings.pop(best_key, None)
        all_db_listings[ik] = (best_id, True, None)
        id_to_ik[best_id] = ik

        # 残りの重複レコードを削除（CASCADE で子テーブルごと原子的に削除される）
        for old_key, old_id, _ in candidates[1:]:
            if old_id == best_id:
                continue
            # 削除対象を統合先として指している tombstone を best に付け替え
            # （FK RESTRICT による削除失敗と、SET NULL 的なサイレント蘇生解除の両方を防ぐ）
            (client.table("listings")
             .update({"merged_into": best_id}, returning="minimal")
             .eq("merged_into", old_id).execute())
            _delete_duplicate_listing(client, old_id)
            _deleted_ids.add(old_id)
            existing_listings.pop(old_key, None)
            all_db_listings.pop(old_key, None)

        return ik

    def _reconcile_by_url(url: str | None, item_floor: int | None, new_ik: str) -> tuple[int, str] | None:
        """source+URL 突合。同一URLの既存 listing があれば survivor に収束し、
        (survivor_id, canonical_ik) を返す（フェーズ2の upsert で可変フィールドが更新される）。

        - 階が両方非Noneで異なる候補はマージ対象から除外（別住戸として温存）。
        - 統合済み tombstone（merged_into 付き）は survivor 候補から除外（蘇生防止）。
        - マージ可能候補が無ければ None（identity_key 突合の既存パスへ委ねる）。
        - 余剰 listing は merged_into tombstone を付けてから CASCADE 削除（既存統合機構と同一）。
        - 同一ランで既に収束済みのURLは再付け替えせず、確定済みの canonical_ik を返す
          （1スクレイプ内に同一URLが複数 item で出ても survivor の ik を1つに固定）。
        """
        if not url:
            return None
        prior = _url_claimed.get(url)
        if prior is not None:
            survivor_id, canonical_ik = prior
            if survivor_id not in _deleted_ids:
                return survivor_id, canonical_ik
        candidates = [lid for lid in url_index.get(url, []) if lid not in _deleted_ids]
        # 階が item と矛盾せず、かつ統合済み tombstone でない候補のみマージ対象。
        # 矛盾候補・tombstone は温存して索引に残し、既存の redirect 機構に委ねる。
        def _is_tombstone(lid: int) -> bool:
            entry = all_db_listings.get(id_to_ik.get(lid, ""))
            return bool(entry and entry[2] is not None)

        mergeable = [
            lid for lid in candidates
            if _url_merge_allowed(item_floor, _floor_from_identity_key(id_to_ik.get(lid)))
            and not _is_tombstone(lid)
        ]
        if not mergeable:
            return None
        survivor_id, excess = _select_url_survivor(mergeable)

        for old_id in excess:
            if old_id == survivor_id or old_id in _deleted_ids:
                continue
            # 削除対象を指す tombstone を survivor に付け替えてから削除
            (client.table("listings")
             .update({"merged_into": survivor_id}, returning="minimal")
             .eq("merged_into", old_id).execute())
            _delete_duplicate_listing(client, old_id)
            _deleted_ids.add(old_id)
            old_ik = id_to_ik.pop(old_id, None)
            if old_ik:
                existing_listings.pop(old_ik, None)
                all_db_listings.pop(old_ik, None)

        # survivor を新しい identity_key に付け替え（_resolve_identity_key 末尾と同一手順）
        survivor_old_ik = id_to_ik.get(survivor_id)
        if survivor_old_ik != new_ik:
            try:
                (client.table("listings")
                 .update({"identity_key": new_ik}, returning="minimal")
                 .eq("id", survivor_id).execute())
            except Exception as e:
                if not _is_identity_key_conflict(e):
                    raise
                # new_ik を別レコードが既に保持。URL 一致では item は survivor（同一URL=同一住戸）
                # に属するため、衝突相手へリダイレクトせず survivor を既存 ik のまま維持して
                # URL 収束だけ行い、source 全体の中断を防ぐ（付け替えは諦める）。
                # survivor は :600 で tombstone 除外済みのため、現行 ik での upsert は蘇生を招かない。
                # canonical_ik は survivor の現行 ik。
                logger.warning(
                    "[supabase] identity_key 衝突のため URL survivor 付け替えスキップ "
                    "(new_ik=%s, survivor_id=%d) — 既存 ik=%s を維持",
                    new_ik, survivor_id, survivor_old_ik)
                kept = [survivor_id] + [lid for lid in candidates if lid not in mergeable]
                url_index[url] = sorted(set(kept))
                canonical_ik = id_to_ik.get(survivor_id, new_ik)
                _url_claimed[url] = (survivor_id, canonical_ik)
                return survivor_id, canonical_ik
            if survivor_old_ik:
                existing_listings.pop(survivor_old_ik, None)
                all_db_listings.pop(survivor_old_ik, None)
            existing_listings[new_ik] = survivor_id
            all_db_listings[new_ik] = (survivor_id, True, None)
            id_to_ik[survivor_id] = new_ik

        # 索引を再構築: survivor + 温存した候補（別階の別住戸・tombstone）のみ残す
        kept = [survivor_id] + [lid for lid in candidates if lid not in mergeable]
        url_index[url] = sorted(set(kept))
        canonical_ik = id_to_ik.get(survivor_id, new_ik)
        _url_claimed[url] = (survivor_id, canonical_ik)
        return survivor_id, canonical_ik

    # --- フェーズ1: 行構築（identity_key 解決はフォールバック時のみネットワーク）---
    resolved_items: list[tuple[dict, str]] = []
    listing_rows_by_ik: dict[str, dict] = {}  # バッチ upsert は同一キー重複不可のため ik ごとに1行
    redirected_items: list[tuple[dict, int]] = []  # (item, 統合先 listing_id)
    for item in listings:
        if item.get("price_man") is None:
            logger.debug("price_man=None のため除外: source=%s url=%s",
                         item.get("source"), item.get("url"))
            continue
        ik = identity_key_str(item)
        if not ik or all(p in ("None", "") for p in ik.split("|")):
            continue

        # (0) source+URL 突合 — identity_key（面積/築年/名前）のブレを無視して
        # 同一URLは同一 listing に収束させる。ヒットすれば survivor を ik に付け替え済みなので
        # 以降の tombstone/identity_key 突合をスキップして通常の行構築へ進む。
        url_match = _reconcile_by_url(item.get("url"), item.get("floor_position"), ik)
        if url_match is not None:
            # survivor に確定した canonical_ik を採用（同一ラン内の同一URL重複でも
            # 1つの ik に固定され、フェーズ2 upsert が survivor に収束する）。
            _url_survivor_id, ik = url_match
            seen_identity_keys.add(ik)
        else:
            # 統合済み tombstone への一致は再アクティブ化せず統合先へリダイレクト。
            # 統合先の ik を「巡回で確認済み」として掲載終了判定（grace period）から守る
            canonical_id = _resolve_merged_redirect(ik, all_db_listings)
            if canonical_id is not None:
                canonical_ik = id_to_ik.get(canonical_id)
                if canonical_ik:
                    seen_identity_keys.add(canonical_ik)
                redirected_items.append((item, canonical_id))
                continue

            ik = _resolve_identity_key(ik)
            if ik is None:
                # 衝突を安全に解決できず（蘇生回避のため）スキップ。次ラン以降で再試行。
                continue

        # fuzzy 解決の結果が「tombstone のみ一致」だった場合も統合先へリダイレクト
        if _fuzzy_redirect_target:
            canonical_id = _fuzzy_redirect_target.pop()
            canonical_ik = id_to_ik.get(canonical_id)
            if canonical_ik:
                seen_identity_keys.add(canonical_ik)
            redirected_items.append((item, canonical_id))
            continue

        normalized_name = normalize_listing_name(item.get("name") or "")
        listing_row = {
            "identity_key": ik,
            "name": strip_name_brackets(item.get("name", "")),
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

    # リダイレクト分: 統合先が自前ソースで生存中なら何もしない（URL の上書きを防ぐ）。
    # 統合先のソースが死んでいる場合のみ、この掲載をソースとして付け替える
    # （統合先 URL の掲載終了後も重複側 URL で価格追従を継続するため）。
    # 末尾に追加することで、同一 (listing_id, source) は統合先自身の行が優先される。
    redirect_attached = 0
    redirect_reactivate: set[int] = set()
    for item, canonical_id in redirected_items:
        src = existing_sources.get(canonical_id)
        if src and src.get("is_active"):
            continue
        canonical_ik = id_to_ik.get(canonical_id, "")
        planned_items.append((item, canonical_ik, canonical_id))
        redirect_attached += 1
        # 統合先 listing 自体が非アクティブなら復帰させる（物件はまだ売り出し中）
        entry = all_db_listings.get(canonical_ik)
        if entry and not entry[1]:
            redirect_reactivate.add(canonical_id)
    if redirected_items:
        logger.info("[supabase] %s: 統合済み tombstone へのリダイレクト %d 件（ソース付け替え %d 件）",
                    source, len(redirected_items), redirect_attached)
    plan = _plan_source_sync(planned_items, existing_listings, existing_sources, source)
    for key in summary:
        summary[key] += plan.summary[key]

    # --- フェーズ4: バッチ書き込み ---
    _grouped_batch_upsert(client, "listing_sources", plan.source_rows,
                          on_conflict="listing_id,source")
    _grouped_batch_insert(client, "price_history", plan.price_history_rows)
    _grouped_batch_insert(client, "listing_events", plan.event_rows)

    # リダイレクトでソースを引き継いだ非アクティブな統合先を復帰
    if redirect_reactivate:
        (client.table("listings")
         .update({"is_active": True}, returning="minimal")
         .in_("id", sorted(redirect_reactivate))
         .execute())

    # --- 掲載終了（grace period）: 計画 → バッチ実行 ---
    # 一覧巡回が打ち切られたランでは未巡回ページの物件を「掲載終了」と
    # 誤判定しうるため、miss 加算・deactivate をスキップする（フェイルクローズ。
    # db.py の sync_scrape_results と同じゲート）
    truncated = scraper_metrics.source_scan_truncated(source)
    if truncated:
        logger.warning(
            "[supabase] %s: 打ち切り終端 %s を検出 — このランの掲載終了判定（miss加算）をスキップ",
            source, truncated,
        )
        return summary

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
            # 掲載終了物件の画像URLはリンク切れ候補になるため同時にクリアする。
            # これを怠ると非アクティブ物件に suumo_images が残り image_urls_stale が累積する。
            # 打ち切りラン（truncated）では上流の early-return で本ブロック自体に到達しない
            # ため、掲載継続中の物件の画像を誤って消すことはない（フェイルクローズ）。
            (client.table("enrichments")
             .update({"suumo_images": None, "floor_plan_images": None},
                     returning="minimal")
             .in_("listing_id", batch_ids)
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
        "building_group_key", "building_units",
    ]

    count = 0
    batch_map: dict[int, dict] = {}

    # identity_key → listing_id のマッピングをバッチ取得（共通実装）
    from supabase_client import resolve_listing_ids
    all_iks = [identity_key_str(item) for item in listings]
    ik_to_id = resolve_listing_ids(client, all_iks)

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


def resolve_run_id(env: dict | None = None, *, now: datetime | None = None) -> str:
    """1回のパイプライン実行を束ねる run_id を決める（純関数）。

    GHA 上では run-attempt 単位（リトライを区別）、ローカルでは UTC timestamp。
    """
    env = env if env is not None else os.environ
    gha_run_id = env.get("GITHUB_RUN_ID")
    if gha_run_id:
        attempt = env.get("GITHUB_RUN_ATTEMPT") or "1"
        return f"gha-{gha_run_id}-{attempt}"
    ts = (now or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    return f"local-{ts}"


def build_scraping_run_rows(
    summaries: dict[str, dict[str, int]], run_id: str, property_type: str
) -> list[dict]:
    """per-source の sync summary を scraping_runs テーブル行へ変換する純関数。

    source 昇順で安定化する（冪等 upsert・テスト容易性のため）。
    """
    rows: list[dict] = []
    for source in sorted(summaries):
        s = summaries[source]
        rows.append({
            "run_id": run_id,
            "source": source,
            "property_type": property_type,
            "new_count": int(s.get("new", 0)),
            "reappeared_count": int(s.get("reappeared", 0)),
            "updated_count": int(s.get("updated", 0)),
            "removed_count": int(s.get("removed", 0)),
            "unchanged_count": int(s.get("unchanged", 0)),
        })
    return rows


def _record_scraping_runs(
    client, summaries: dict[str, dict[str, int]], *, run_id: str, property_type: str
) -> int:
    """サイト別 sync summary を scraping_runs に upsert する。

    sync 層のサイレント回帰（パースは成功するが真新規挿入が止まる）の検知用。
    記録失敗は本同期処理をブロックしない（呼び出し側で握る）。
    summaries には sync が成功したソースのみ含める（sync 失敗ソースを new=0 で記録すると
    インフラ瞬断を回帰と誤検知するため。全損は scraper_metrics の媒体全損アラートが担当）。
    """
    rows = build_scraping_run_rows(summaries, run_id, property_type)
    if not rows:
        return 0
    (client.table("scraping_runs")
     .upsert(rows, on_conflict="run_id,source,property_type", returning="minimal")
     .execute())
    return len(rows)


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

        run_summaries: dict[str, dict] = {}
        for source, items in sources_in_batch.items():
            try:
                summary = _sync_source_listings(client, items, source, "chuko")
                run_summaries[source] = summary
                logger.info(
                    "[supabase] %s(中古): new=%d updated=%d removed=%d unchanged=%d reappeared=%d",
                    source, summary["new"], summary["updated"], summary["removed"],
                    summary["unchanged"], summary["reappeared"],
                )
            except Exception as e:
                logger.error("[supabase] %s(中古) listings 同期失敗: %s", source, e)

        # サイト別の真新規挿入数を記録（sync 側サイレント回帰の検知用・本処理はブロックしない）
        # run_id は1ラン1回だけ解決し、全ソースで同一値を共有する
        try:
            recorded = _record_scraping_runs(
                client, run_summaries, run_id=resolve_run_id(), property_type="chuko"
            )
            if recorded:
                logger.info("[supabase] scraping_runs: %d ソース記録", recorded)
        except Exception as e:
            logger.warning("[supabase] scraping_runs 記録失敗: %s", e)

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
