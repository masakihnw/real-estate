#!/usr/bin/env python3
"""Supabase の既存 ai_recommendation 結果から claude_cache.db を事前構築する。

初回実行時にキャッシュが空でも API 再呼び出しを回避するためのスクリプト。
"""

from __future__ import annotations

import hashlib
import json
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from logger import get_logger

logger = get_logger(__name__)

CACHE_DB_PATH = Path(__file__).resolve().parent.parent / "data" / "claude_cache.db"

_CACHE_SCHEMA = """
CREATE TABLE IF NOT EXISTS claude_cache (
    cache_key TEXT PRIMARY KEY,
    module TEXT NOT NULL,
    result_json TEXT NOT NULL,
    model TEXT DEFAULT '',
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    created_at TEXT DEFAULT (datetime('now'))
);
CREATE INDEX IF NOT EXISTS idx_claude_cache_module ON claude_cache(module);
"""


def _cache_key(module: str, input_data: dict) -> str:
    data_str = json.dumps(input_data, sort_keys=True, ensure_ascii=False)
    h = hashlib.sha256(data_str.encode()).hexdigest()[:16]
    return f"{module}:{h}"


def _listing_stable_key(listing: dict) -> str:
    fields = json.dumps({
        "name": listing.get("name"), "price_man": listing.get("price_man"),
        "area_m2": listing.get("area_m2"), "layout": listing.get("layout"),
        "built_year": listing.get("built_year"), "walk_min": listing.get("walk_min"),
        "address": listing.get("address"),
    }, sort_keys=True)
    return hashlib.sha256(fields.encode()).hexdigest()[:16]


def main() -> None:
    from claude_investment_summarizer import (
        PROMPT_VERSION,
        _format_buyer_profile,
        _load_buyer_profile,
    )

    import supabase_client
    client = supabase_client.get_client()
    if client is None:
        logger.error("Supabase 未設定: 事前構築スキップ")
        sys.exit(1)

    buyer_profile = _load_buyer_profile()
    buyer_context = _format_buyer_profile(buyer_profile)
    buyer_hash = int(hashlib.sha256(buyer_context.encode()).hexdigest()[:8], 16)

    logger.info("buyer_hash=%d, prompt_version=%s", buyer_hash, PROMPT_VERSION)

    select_fields = (
        "ai_recommendation_score, ai_recommendation_summary, "
        "ai_recommendation_flags, ai_recommendation_action, "
        "ai_recommendation_scenarios"
    )

    all_rows: list[dict] = []
    page_size = 1000
    offset = 0
    while True:
        resp = (
            client.table("enrichments")
            .select(f"listing_id, {select_fields}")
            .filter("ai_recommendation_score", "not.is", "null")
            .range(offset, offset + page_size - 1)
            .execute()
        )
        if not resp.data:
            break
        all_rows.extend(resp.data)
        if len(resp.data) < page_size:
            break
        offset += page_size

    if not all_rows:
        logger.info("ai_recommendation データなし: 事前構築スキップ")
        return

    listing_ids = [r["listing_id"] for r in all_rows]
    listing_map: dict[int, dict] = {}
    for i in range(0, len(listing_ids), 100):
        chunk = listing_ids[i:i + 100]
        resp = (
            client.table("listings")
            .select("id, name, price_man, area_m2, layout, built_year, walk_min, address")
            .in_("id", chunk)
            .execute()
        )
        if resp.data:
            for row in resp.data:
                listing_map[row["id"]] = row

    CACHE_DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(CACHE_DB_PATH))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(_CACHE_SCHEMA)

    existing_keys = {
        row[0]
        for row in conn.execute(
            "SELECT cache_key FROM claude_cache WHERE module = 'ai_recommendation'"
        ).fetchall()
    }

    inserted = 0
    skipped = 0
    for row in all_rows:
        listing = listing_map.get(row["listing_id"])
        if not listing:
            continue

        cache_key_data = {
            "buyer_hash": buyer_hash,
            "listing_key": _listing_stable_key(listing),
            "prompt_version": PROMPT_VERSION,
        }
        key = _cache_key("ai_recommendation", cache_key_data)

        if key in existing_keys:
            skipped += 1
            continue

        flags = row.get("ai_recommendation_flags") or []
        if isinstance(flags, str):
            try:
                flags = json.loads(flags)
            except (json.JSONDecodeError, TypeError):
                flags = []

        scenarios = row.get("ai_recommendation_scenarios") or []
        if isinstance(scenarios, str):
            try:
                scenarios = json.loads(scenarios)
            except (json.JSONDecodeError, TypeError):
                scenarios = []

        result = {
            "score": row["ai_recommendation_score"],
            "conclusion": row.get("ai_recommendation_summary") or "",
            "flags": flags,
            "action": row.get("ai_recommendation_action") or "",
            "scenarios": scenarios,
        }

        conn.execute(
            """INSERT OR REPLACE INTO claude_cache
               (cache_key, module, result_json, model, input_tokens, output_tokens)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (key, "ai_recommendation", json.dumps(result, ensure_ascii=False),
             "prepopulated", 0, 0),
        )
        inserted += 1

    conn.commit()
    conn.close()

    logger.info(
        "キャッシュ事前構築完了: %d件挿入, %d件既存スキップ (計%d件)",
        inserted, skipped, inserted + skipped,
    )


if __name__ == "__main__":
    main()
