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

# 各 enricher が追加するフィールドのホワイトリスト
# これ以外のフィールドは base の値を維持（誤上書き防止）
ENRICHER_FIELDS: dict[str, set[str]] = {
    # Track PREP: build_units_cache → merge_detail_cache
    "units_cache": {
        "total_units",
        "floor_position",
        "floor_total",
        "floor_structure",
        "ownership",
        "management_fee",
        "repair_reserve_fund",
        "direction",
        "balcony_area_m2",
        "parking",
        "constructor",
        "zoning",
        "repair_fund_onetime",
        "delivery_date",
        "feature_tags",
        "floor_plan_images",
        "suumo_images",
    },
    # Track A: sumai_surfin_enricher
    "sumai_surfin": {
        "ss_sumai_surfin_url",
        "ss_address",
        "ss_oki_price_70m2",
        "ss_value_judgment",
        "ss_station_rank",
        "ss_ward_rank",
        "ss_appreciation_rate",
        "ss_favorite_count",
        "ss_purchase_judgment",
        "ss_profit_pct",
        "ss_m2_discount",
        "ss_new_m2_price",
        "ss_forecast_m2_price",
        "ss_forecast_change_rate",
        "ss_lookup_status",
        "ss_radar_data",
        "ss_past_market_trends",
        "ss_surrounding_properties",
        "ss_sim_monthly_payment",
        "ss_sim_total_payment",
        "ss_sim_interest_total",
        "ss_sim_base_price",
        "ss_loan_balance_5y",
        "ss_loan_balance_10y",
        "ss_loan_balance_15y",
        "ss_loan_balance_20y",
        "ss_loan_balance_25y",
        "ss_loan_balance_30y",
        "ss_loan_balance_35y",
        "address",  # sumai_surfin が上書きする場合あり
    },
    # Track B: geocode_cross_validator + hazard_enricher
    "geocode_hazard": {
        "latitude",
        "longitude",
        "geocode_confidence",
        "geocode_fixed",
        "hazard_info",
    },
    # Track C: commute_enricher
    "commute": {
        "commute_info",
    },
    # Track D: reinfolib_enricher
    "reinfolib": {
        "reinfolib_market_data",
    },
    # Track E: estat_enricher
    "estat": {
        "estat_population_data",
    },
}

# 全 enricher フィールドの union
ALL_ENRICHER_FIELDS = set()
for fields in ENRICHER_FIELDS.values():
    ALL_ENRICHER_FIELDS |= fields


def load_json_safe(path: Path) -> list[dict] | None:
    """JSON ファイルを安全に読み込む。失敗時は None を返す。"""
    if not path.exists():
        print(f"[merge] スキップ: {path} が存在しません", file=sys.stderr)
        return None
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        if not isinstance(data, list):
            print(f"[merge] スキップ: {path} がリスト形式ではありません", file=sys.stderr)
            return None
        return data
    except (json.JSONDecodeError, OSError) as e:
        print(f"[merge] スキップ: {path} の読み込みに失敗: {e}", file=sys.stderr)
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
            for field in ALL_ENRICHER_FIELDS:
                if field in enriched_item:
                    # base にないフィールド or enriched で値が変わったフィールドを取り込み
                    if field not in item or item[field] != enriched_item[field]:
                        item[field] = enriched_item[field]
                        merged_count += 1

        print(
            f"[merge] {enriched_path.name}: {merged_count} フィールドをマージ",
            file=sys.stderr,
        )

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
        print("[merge] エラー: base ファイルが読み込めません", file=sys.stderr)
        sys.exit(1)

    enriched_paths = [Path(p) for p in args.enriched]
    result = merge(base_data, enriched_paths)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    print(f"[merge] 完了: {len(result)} 件を {args.output} に出力", file=sys.stderr)


if __name__ == "__main__":
    main()
