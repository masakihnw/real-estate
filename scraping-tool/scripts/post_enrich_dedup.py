#!/usr/bin/env python3
"""
enrichment 後の再重複排除。

enricher が floor_position 等を埋めた後に dedupe_listings を再実行し、
enrichment 前には検知できなかった重複を解消する。
Supabase 同期の前に実行すること。

使い方:
  python3 scripts/post_enrich_dedup.py results/latest.json
  python3 scripts/post_enrich_dedup.py results/latest.json results/latest_shinchiku.json
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from logger import get_logger
from main import dedupe_listings
from scripts.validate_data import detect_ui_duplicates

logger = get_logger(__name__)


def redeup_file(path: Path) -> int:
    if not path.exists() or path.stat().st_size == 0:
        return 0
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, list) or len(data) == 0:
        return 0

    dupes = detect_ui_duplicates(data)
    if not dupes:
        logger.info("[post_enrich_dedup] %s: UI重複なし（スキップ）", path.name)
        return 0

    before = len(data)
    deduped = dedupe_listings(data)
    after = len(deduped)
    removed = before - after

    with open(path, "w", encoding="utf-8") as f:
        json.dump(deduped, f, ensure_ascii=False, indent=2)

    remaining = detect_ui_duplicates(deduped)
    logger.info(
        "[post_enrich_dedup] %s: %d件 → %d件（%d件マージ）、残存UI重複: %d",
        path.name, before, after, removed, len(remaining),
    )
    return removed


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <json_file> [json_file...]", file=sys.stderr)
        sys.exit(1)

    total_removed = 0
    for arg in sys.argv[1:]:
        total_removed += redeup_file(Path(arg))

    if total_removed > 0:
        logger.info("[post_enrich_dedup] 合計 %d 件の重複をマージしました", total_removed)


if __name__ == "__main__":
    main()
