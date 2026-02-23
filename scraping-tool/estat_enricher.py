#!/usr/bin/env python3
"""
物件 JSON に e-Stat 人口動態データ・高齢化率データを付与する enricher。

data/estat_population.json + data/estat_aging.json を参照し、
各物件に以下のフィールドを追加する:

  estat_population_data (JSON文字列):
    {
      "ward": "江東区",
      "latest_population": 528950,
      "latest_households": 287840,
      "pop_change_1yr_pct": 1.5,
      "pop_change_5yr_pct": 7.8,
      "population_history": [...],
      "household_history": [...],
      "aging_rate_history": [{"year": "2000", "aging_rate": 16.6}, ...],
      "latest_aging_rate": 21.3,
      "national_aging_history": [{"year": "2000", "aging_rate": 17.3}, ...],
      "tokyo23_avg_aging_history": [{"year": "2000", "aging_rate": 17.5}, ...],
      "data_source": "e-Stat（総務省統計局）"
    }

使い方:
  python3 estat_enricher.py --input results/latest.json --output results/latest.json

※ API は叩かない。ローカルキャッシュのみ参照。
"""

import argparse
import json
import os
import re
import sys
from typing import Optional

from parse_utils import extract_ward as _extract_ward_shared

# ---------------------------------------------------------------------------
# キャッシュ読み込み
# ---------------------------------------------------------------------------

DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
POPULATION_CACHE = os.path.join(DATA_DIR, "estat_population.json")
AGING_CACHE = os.path.join(DATA_DIR, "estat_aging.json")


def load_json_file(path: str) -> Optional[dict]:
    """JSON ファイルを読み込む。なければ None。"""
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# 住所から区名を抽出
# ---------------------------------------------------------------------------

def extract_ward(address: Optional[str]) -> Optional[str]:
    """住所文字列から区名を抽出。parse_utils.extract_ward に委譲。"""
    return _extract_ward_shared(address)


# ---------------------------------------------------------------------------
# Enricher 本体
# ---------------------------------------------------------------------------

def enrich_estat_population(listings: list) -> int:
    """
    物件リストに estat_population_data を追加する。
    人口動態データ + 高齢化率データを統合して付与。
    """
    population = load_json_file(POPULATION_CACHE)
    aging = load_json_file(AGING_CACHE)

    if not population:
        print("警告: estat_population.json が見つかりません。スキップします。", file=sys.stderr)
        print(f"  期待パス: {POPULATION_CACHE}", file=sys.stderr)
        return 0

    pop_by_ward = population.get("by_ward", {})
    data_source = population.get("data_source", "e-Stat（総務省統計局）")

    aging_by_ward = aging.get("by_ward", {}) if aging else {}
    national_aging = aging.get("national_aging_history", []) if aging else []
    tokyo23_avg_aging = aging.get("tokyo23_avg_aging_history", []) if aging else []

    enriched_count = 0

    for listing in listings:
        ward = extract_ward(listing.get("ss_address") or listing.get("address"))
        if not ward:
            continue

        ward_data = pop_by_ward.get(ward)
        if not ward_data:
            continue

        pop_data = {
            "ward": ward,
            "latest_population": ward_data.get("latest_population"),
            "latest_households": ward_data.get("latest_households"),
            "pop_change_1yr_pct": ward_data.get("pop_change_1yr_pct"),
            "pop_change_5yr_pct": ward_data.get("pop_change_5yr_pct"),
            "population_history": ward_data.get("population_history", []),
            "household_history": ward_data.get("household_history", []),
            "data_source": data_source,
        }

        ward_aging = aging_by_ward.get(ward, {})
        if ward_aging:
            pop_data["aging_rate_history"] = ward_aging.get("aging_rate_history", [])
            pop_data["latest_aging_rate"] = ward_aging.get("latest_aging_rate")
            pop_data["national_aging_history"] = national_aging
            pop_data["tokyo23_avg_aging_history"] = tokyo23_avg_aging

        listing["estat_population_data"] = json.dumps(
            pop_data, ensure_ascii=False
        )
        enriched_count += 1

    return enriched_count


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="物件JSONにe-Stat人口動態データを付与"
    )
    ap.add_argument("--input", required=True, help="入力JSONファイル")
    ap.add_argument("--output", required=True, help="出力JSONファイル")
    args = ap.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        listings = json.load(f)

    count = enrich_estat_population(listings)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    print(
        f"e-Stat 人口動態 enrichment 完了: {count}/{len(listings)} 件に人口データを付与",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
