#!/usr/bin/env python3
"""
物件 JSON に e-Stat 人口動態データを付与する enricher。

data/estat_population.json を参照し、各物件に以下のフィールドを追加する:

  estat_population_data (JSON文字列):
    {
      "ward": "江東区",
      "latest_population": 528950,
      "latest_households": 287840,
      "pop_change_1yr_pct": 1.5,
      "pop_change_5yr_pct": 7.8,
      "population_history": [
        {"year": "2020", "population": 524310},
        ...
      ],
      "household_history": [
        {"year": "2020", "households": 271500},
        ...
      ],
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

# ---------------------------------------------------------------------------
# キャッシュ読み込み
# ---------------------------------------------------------------------------

DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
POPULATION_CACHE = os.path.join(DATA_DIR, "estat_population.json")


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
    """住所文字列から区名を抽出 (例: '東京都江東区豊洲5丁目' → '江東区')。"""
    if not address:
        return None
    m = re.search(r"(?<=[都道府県])\S+?区", address)
    if m:
        return m.group(0)
    return None


# ---------------------------------------------------------------------------
# Enricher 本体
# ---------------------------------------------------------------------------

def enrich_estat_population(listings: list) -> int:
    """
    物件リストに estat_population_data を追加する。
    既にある場合はスキップ。
    """
    population = load_json_file(POPULATION_CACHE)

    if not population:
        print("警告: estat_population.json が見つかりません。スキップします。", file=sys.stderr)
        print(f"  期待パス: {POPULATION_CACHE}", file=sys.stderr)
        return 0

    pop_by_ward = population.get("by_ward", {})
    data_source = population.get("data_source", "e-Stat（総務省統計局）")

    enriched_count = 0

    for listing in listings:
        # 既にデータがある場合はスキップ
        if listing.get("estat_population_data"):
            continue

        # 住所から区名を抽出
        ward = extract_ward(listing.get("address"))
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
