#!/usr/bin/env python3
"""
各 enricher が別コピーで作業した結果をフィールドレベルで統合する。

使い方:
  python3 merge_enrichments.py --base latest.json \
    --enriched latest_uc.json latest_ss.json latest_hz.json latest_cm.json latest_ri.json latest_es.json \
    --output latest.json

ロジック:
  1. base (Phase 1 完了後) の各 listing を基準
  2. 各 enriched ファイルについて:
     - ファイルが存在しない → スキップ (enricher 失敗)
     - JSON パースエラー → スキップ (出力破損)
     - listing を url キーで照合
     - ENRICHER_FIELDS に含まれるフィールドのみ取り込み
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from logger import get_logger
logger = get_logger(__name__)

# enricher ごとのフィールドマッチングルール
# プレフィックスベース: そのプレフィックスで始まるフィールドは全て取り込む
# 個別指定: プレフィックスに収まらないフィールドを明示的に列挙
ENRICHER_PREFIXES: dict[str, list[str]] = {
    "sumai_surfin": ["ss_"],
    "geocode_hazard": ["hazard_", "geocode_"],
    "commute": ["commute_"],
    "commute_gmaps": ["commute_"],
    "reinfolib": ["reinfolib_"],
    "estat": ["estat_"],
    "mansion_review": ["mansion_review_"],
}

ENRICHER_EXACT: dict[str, set[str]] = {
    "units_cache": {
        "total_units", "floor_position", "floor_total", "floor_structure",
        "ownership", "management_fee", "repair_reserve_fund", "direction",
        "balcony_area_m2", "parking", "constructor", "zoning",
        "repair_fund_onetime", "delivery_date", "feature_tags",
        "floor_plan_images", "suumo_images",
    },
    "sumai_surfin": {"address"},
    "geocode_hazard": {"latitude", "longitude"},
    "claude_text": {"extracted_features"},
    "claude_dedup": {"dedup_confidence", "dedup_reasoning", "dedup_candidates"},
    "claude_image": {"image_categories", "best_thumbnail_url"},
    "investment": {
        "price_fairness_score", "resale_liquidity_score", "listing_score",
        "competing_listings_count", "investment_summary", "highlight_badge",
        "building_group_key", "building_units",
    },
    "ai_recommendation": {
        "ai_recommendation_score", "ai_recommendation_summary",
        "ai_recommendation_flags", "ai_recommendation_action",
        "ai_recommendation_scenarios", "key_strengths", "key_risks",
    },
}


def _is_enricher_field(field: str) -> bool:
    """フィールドがいずれかの enricher に属するかを判定する。"""
    for prefixes in ENRICHER_PREFIXES.values():
        for prefix in prefixes:
            if field.startswith(prefix):
                return True
    for exact_fields in ENRICHER_EXACT.values():
        if field in exact_fields:
            return True
    return False


def load_json_safe(path: Path) -> list[dict] | None:
    """JSON ファイルを安全に読み込む。失敗時は None を返す。"""
    if not path.exists():
        logger.warning(f"[merge] スキップ: {path} が存在しません")
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, list):
            logger.warning(f"[merge] スキップ: {path} がリスト形式ではありません")
            return None
        return data
    except (json.JSONDecodeError, OSError) as e:
        logger.error(f"[merge] スキップ: {path} の読み込みに失敗: {e}")
        return None


def build_index(listings: list[dict]) -> dict[str, dict]:
    """URL をキーにした辞書を構築。URL がない場合は name + address で照合。"""
    index: dict[str, dict] = {}
    for item in listings:
        key = item.get("url") or f"{item.get('name', '')}|{item.get('address', '')}"
        if key:
            index[key] = item
    return index


def merge(base: list[dict], enriched_files: list[Path]) -> list[dict]:
    """base に各 enriched ファイルのフィールドをマージして返す。"""
    for enriched_path in enriched_files:
        enriched_data = load_json_safe(enriched_path)
        if enriched_data is None:
            continue

        enriched_index = build_index(enriched_data)
        merged_count = 0

        for item in base:
            key = item.get("url") or f"{item.get('name', '')}|{item.get('address', '')}"
            if not key or key not in enriched_index:
                continue

            enriched_item = enriched_index[key]
            for field, value in enriched_item.items():
                if value is None:
                    continue
                if not _is_enricher_field(field):
                    continue
                if field not in item or item[field] != value:
                    item[field] = value
                    merged_count += 1

        logger.info(f"[merge] {enriched_path.name}: {merged_count} フィールドをマージ")

    return base


def main() -> None:
    parser = argparse.ArgumentParser(description="enricher 結果のフィールドレベルマージ")
    parser.add_argument("--base", required=True, help="ベース JSON ファイル (Phase 1 出力)")
    parser.add_argument(
        "--enriched",
        nargs="+",
        required=True,
        help="enricher 出力ファイル群",
    )
    parser.add_argument("--output", required=True, help="出力先")
    args = parser.parse_args()

    base_data = load_json_safe(Path(args.base))
    if base_data is None:
        print("[merge] エラー: base ファイルが読み込めません")
        sys.exit(1)

    enriched_paths = [Path(p) for p in args.enriched]
    result = merge(base_data, enriched_paths)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    logger.info(f"[merge] 完了: {len(result)} 件を {args.output} に出力")


if __name__ == "__main__":
    main()
