#!/usr/bin/env python3
"""Supabase 全テーブルの論理バックアップ（テーブルごとに JSONL.gz）を生成する。

無料プランには自動バックアップ / PITR が無いため、その代替として週次で全データを
退避する。スキーマ(DDL)は supabase/migrations/ が正（source of truth）なので、
本スクリプトが退避するのは **データのみ**。復元は「migrations 適用 → 各 JSONL.gz を
upsert」で行う。

使い方:
    python3 scripts/backup_supabase.py --output-dir backups

環境変数 SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY が必要。
"""
from __future__ import annotations

import argparse
import gzip
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from logger import get_logger  # noqa: E402
from supabase_client import fetch_paginated, get_client  # noqa: E402

logger = get_logger(__name__)

JST = timezone(timedelta(hours=9))

# list_backup_tables RPC（migration 053）が使えない環境向けフォールバック。
# public スキーマの実テーブル（2026-07 時点）。RPC 優先・これは保険。
FALLBACK_TABLES: tuple[str, ...] = (
    "ai_prompts", "app_config", "building_groups", "buyer_daily_briefs",
    "buyer_preference_summaries", "buyer_profiles", "enrichments",
    "health_check_logs", "listing_events", "listing_sources", "listings",
    "near_misses", "notification_drafts", "notification_state",
    "pipeline_issues", "price_history", "scraping_config", "scraping_runs",
    "station_commute_times", "transaction_metadata", "transactions",
    "user_annotations", "user_building_preferences",
)


def list_tables(client) -> list[str]:
    """バックアップ対象テーブル名を返す。RPC 優先、失敗時はフォールバック。"""
    try:
        resp = client.rpc("list_backup_tables").execute()
        tables = [r["table_name"] for r in (resp.data or []) if r.get("table_name")]
        if tables:
            return tables
        logger.warning("list_backup_tables RPC が空を返却。フォールバックを使用")
    except Exception as e:
        logger.warning("list_backup_tables RPC 失敗、フォールバック使用: %s", e)
    return list(FALLBACK_TABLES)


def backup_table(client, table: str, out_dir: Path) -> int:
    """1テーブルを JSONL.gz に書き出し、行数を返す。"""
    rows = fetch_paginated(client, table, "*")
    out_path = out_dir / f"{table}.jsonl.gz"
    with gzip.open(out_path, "wt", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False, default=str))
            f.write("\n")
    return len(rows)


def run_backup(out_root: Path, now: datetime | None = None) -> dict:
    """全テーブルをバックアップし manifest を返す。"""
    client = get_client()
    if client is None:
        raise SystemExit("SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY 未設定: バックアップ不可")

    stamp = (now or datetime.now(JST)).strftime("%Y%m%d_%H%M%S")
    out_dir = out_root / f"supabase_backup_{stamp}"
    out_dir.mkdir(parents=True, exist_ok=True)

    tables = list_tables(client)
    manifest: dict = {"created_at_jst": stamp, "table_count": len(tables), "tables": {}}
    total = 0
    for t in tables:
        try:
            n = backup_table(client, t, out_dir)
            manifest["tables"][t] = n
            total += n
            logger.info("backup %s: %d 行", t, n)
        except Exception as e:
            # フェイルクローズ: 失敗はマニフェストに残し、最後に非0終了させる。
            manifest["tables"][t] = f"ERROR: {e}"
            logger.error("backup 失敗 %s: %s", t, e)

    manifest["total_rows"] = total
    (out_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    logger.info("バックアップ完了: %s (%d テーブル / %d 行)", out_dir, len(tables), total)
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description="Supabase 全データ論理バックアップ")
    parser.add_argument(
        "--output-dir", "-o", default="backups", help="出力先ディレクトリ（既定: backups）"
    )
    args = parser.parse_args()

    manifest = run_backup(Path(args.output_dir))

    errors = [t for t, v in manifest["tables"].items() if isinstance(v, str)]
    if errors:
        logger.error("一部テーブルのバックアップに失敗: %s", errors)
        sys.exit(1)


if __name__ == "__main__":
    main()
