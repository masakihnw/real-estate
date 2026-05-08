"""enricher から Supabase enrichments テーブルへの直接書き込みユーティリティ。

各 enricher の main() 末尾で呼び出すことで、JSON 出力に加えて
Supabase にも enrichment データを書き込む (dual-write)。

SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 未設定時は自動スキップ。
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from logger import get_logger
from supabase_client import get_client

logger = get_logger(__name__)

BATCH_SIZE = 500
MAX_STRING_BYTES = 10_000


def _sanitize_value(obj: object) -> object:
    if isinstance(obj, float):
        if math.isnan(obj) or math.isinf(obj):
            return None
        return obj
    if isinstance(obj, str):
        if obj.strip().lower() in ("nan", "infinity", "-infinity", "inf", "-inf"):
            return None
        s = obj.replace("\x00", "")
        if s and s[0] in ("{", "["):
            try:
                parsed = json.loads(s)
                sanitized = _sanitize_value(parsed)
                s = json.dumps(sanitized, ensure_ascii=False, allow_nan=False)
            except (json.JSONDecodeError, ValueError):
                pass
        if len(s.encode("utf-8")) > MAX_STRING_BYTES:
            s = s.encode("utf-8")[:MAX_STRING_BYTES].decode("utf-8", errors="ignore")
        return s
    if isinstance(obj, dict):
        return {k: _sanitize_value(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_sanitize_value(item) for item in obj]
    return obj


def _resolve_listing_ids(
    client: object, listings: list[dict]
) -> dict[str, int]:
    from report_utils import identity_key_str

    all_iks = list({identity_key_str(item) for item in listings if identity_key_str(item)})
    if not all_iks:
        return {}

    ik_to_id: dict[str, int] = {}
    for i in range(0, len(all_iks), 100):
        chunk = all_iks[i : i + 100]
        try:
            resp = (
                client.table("listings")
                .select("id, identity_key")
                .in_("identity_key", chunk)
                .execute()
            )
            if resp.data:
                for row in resp.data:
                    ik_to_id[row["identity_key"]] = row["id"]
        except Exception as e:
            logger.error(f"listing_id 解決エラー (chunk {i}): {e}")
            for ik in chunk:
                try:
                    resp = (
                        client.table("listings")
                        .select("id, identity_key")
                        .eq("identity_key", ik)
                        .execute()
                    )
                    if resp.data:
                        ik_to_id[resp.data[0]["identity_key"]] = resp.data[0]["id"]
                except Exception as row_err:
                    logger.debug(f"per-row fallback 失敗 (ik={ik[:40]}): {row_err}")
    return ik_to_id


def write_enrichments(
    listings: list[dict],
    fields: list[str],
    enricher_name: str,
) -> int:
    """listings の指定フィールドを Supabase enrichments テーブルに upsert する。

    Returns:
        書き込んだ行数。Supabase 未設定時は 0。
    """
    client = get_client()
    if client is None:
        logger.info(f"[{enricher_name}] Supabase 未設定: dual-write スキップ")
        return 0

    from report_utils import identity_key_str

    ik_to_id = _resolve_listing_ids(client, listings)
    if not ik_to_id:
        logger.warning(f"[{enricher_name}] listing_id を解決できませんでした")
        return 0

    batch_map: dict[int, dict] = {}
    for item in listings:
        ik = identity_key_str(item)
        if not ik:
            continue
        listing_id = ik_to_id.get(ik)
        if not listing_id:
            continue

        row = {"listing_id": listing_id}
        has_data = False
        for field in fields:
            val = item.get(field)
            if val is not None:
                row[field] = val
                has_data = True

        if has_data:
            if listing_id in batch_map:
                batch_map[listing_id].update(row)
            else:
                batch_map[listing_id] = row

    if not batch_map:
        logger.info(f"[{enricher_name}] 書き込み対象なし")
        return 0

    rows = list(batch_map.values())
    total = 0
    for i in range(0, len(rows), BATCH_SIZE):
        batch = [_sanitize_value(r) for r in rows[i : i + BATCH_SIZE]]
        try:
            resp = (
                client.table("enrichments")
                .upsert(batch, on_conflict="listing_id")
                .execute()
            )
            total += len(resp.data) if resp.data else 0
        except Exception as e:
            logger.error(f"[{enricher_name}] Supabase upsert エラー: {e}")

    logger.info(f"[{enricher_name}] Supabase に {total} 件書き込み完了")
    return total
