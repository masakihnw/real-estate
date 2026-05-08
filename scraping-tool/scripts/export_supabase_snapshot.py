#!/usr/bin/env python3
"""
Supabase listings_feed ビューから JSON スナップショットをエクスポートする。

Phase 3: Supabase を主ストアとし、JSON はスナップショット/バックアップとして生成。
merge_enrichments.py の代替として使用可能。

使い方:
  python3 scripts/export_supabase_snapshot.py \
    --output results/latest.json \
    --property-type chuko
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from logger import get_logger
from supabase_client import get_client

logger = get_logger(__name__)

BATCH_SIZE = 1000


def export_listings(
    property_type: str = "chuko",
    active_only: bool = True,
) -> list[dict]:
    client = get_client()
    if client is None:
        logger.error("Supabase クライアント未設定")
        return []

    listings: list[dict] = []
    offset = 0

    while True:
        query = (
            client.table("listings_feed")
            .select("*")
            .eq("property_type", property_type)
        )
        if active_only:
            query = query.eq("is_active", True)

        resp = query.range(offset, offset + BATCH_SIZE - 1).execute()

        if not resp.data:
            break

        listings.extend(resp.data)
        if len(resp.data) < BATCH_SIZE:
            break
        offset += BATCH_SIZE

    logger.info(f"Supabase から {len(listings)} 件取得 (property_type={property_type})")
    return listings


def _flatten_listing(row: dict) -> dict:
    """listings_feed のカラム名を JSON 互換フォーマットに変換する。"""
    result = dict(row)

    if result.get("price_history_json"):
        result["price_history"] = result.pop("price_history_json")
    else:
        result.pop("price_history_json", None)

    if result.get("alt_sources_json"):
        result["alt_sources_view"] = result.pop("alt_sources_json")
    else:
        result.pop("alt_sources_json", None)

    for key in list(result.keys()):
        if result[key] is None:
            del result[key]

    return result


def main() -> None:
    parser = argparse.ArgumentParser(description="Supabase → JSON snapshot export")
    parser.add_argument("--output", "-o", required=True, help="出力 JSON ファイル")
    parser.add_argument(
        "--property-type",
        default="chuko",
        choices=["chuko", "shinchiku"],
        help="物件タイプ",
    )
    parser.add_argument(
        "--include-inactive",
        action="store_true",
        help="非アクティブ物件も含める",
    )
    args = parser.parse_args()

    listings = export_listings(
        property_type=args.property_type,
        active_only=not args.include_inactive,
    )

    if not listings:
        logger.error("エクスポート対象が0件です — Supabase の接続またはビューを確認してください")
        sys.exit(1)

    enrichment_check_fields = ["hazard_info", "commute_info", "ss_lookup_status"]
    for field in enrichment_check_fields:
        filled = sum(1 for r in listings if r.get(field) is not None)
        pct = filled / len(listings) * 100
        logger.info(f"enrichment 充足率: {field} = {filled}/{len(listings)} ({pct:.0f}%)")
        if pct < 10:
            logger.error(
                f"enrichments テーブルのデータが不十分です ({field}: {pct:.0f}%%) "
                f"— dual-write が未実行の可能性があります。JSON merge にフォールバックします。"
            )
            sys.exit(1)

    flat = [_flatten_listing(row) for row in listings]

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = output_path.with_suffix(".json.tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(flat, f, ensure_ascii=False, indent=2)
    tmp_path.replace(output_path)

    logger.info(f"エクスポート完了: {len(flat)} 件 → {output_path}")


if __name__ == "__main__":
    main()
