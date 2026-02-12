#!/usr/bin/env python3
"""
MCP API レスポンスのJSONファイルから ward_price_history.json を構築。

usage:
  python3 scripts/collect_historical_prices.py data/raw_responses/

raw_responses/ ディレクトリに以下の命名規則でJSONファイルを配置:
  {ward_code}_{year}Q{quarter}.json
  例: 13101_2021Q2.json

MCP API で取得したレスポンスをそのまま保存したものを入力とする。
"""

import json
import os
import statistics
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

WARD_CODE_TO_NAME = {
    "13101": "千代田区", "13102": "中央区", "13103": "港区",
    "13104": "新宿区", "13105": "文京区", "13106": "台東区",
    "13107": "墨田区", "13108": "江東区", "13109": "品川区",
    "13110": "目黒区", "13111": "大田区", "13112": "世田谷区",
    "13113": "渋谷区", "13114": "中野区", "13115": "杉並区",
    "13116": "豊島区", "13117": "北区", "13118": "荒川区",
    "13119": "板橋区", "13120": "練馬区", "13121": "足立区",
    "13122": "葛飾区", "13123": "江戸川区",
}


def compute_m2_prices_from_response(data: dict) -> List[float]:
    """APIレスポンスから中古マンションのm²単価リストを算出。"""
    m2_prices = []
    for item in data.get("data", []):
        if "中古マンション" not in item.get("Type", ""):
            continue
        try:
            price = float(str(item.get("TradePrice", "0")).replace(",", ""))
            area = float(str(item.get("Area", "0")).replace(",", ""))
            if price > 0 and area > 0:
                m2_prices.append(price / area)
        except (ValueError, TypeError):
            continue
    return m2_prices


def process_inline_data(ward_code: str, year: int, quarter: int, data: dict) -> Optional[dict]:
    """APIレスポンスから1つのデータポイントを生成。"""
    m2_prices = compute_m2_prices_from_response(data)
    if not m2_prices:
        return None
    return {
        "median_m2_price": round(statistics.median(m2_prices)),
        "mean_m2_price": round(statistics.mean(m2_prices)),
        "count": len(m2_prices),
    }


def build_history_from_data(
    ward_data: Dict[str, Dict[str, dict]]
) -> dict:
    """
    ward_data: { ward_name: { "2021Q2": {median_m2_price, mean_m2_price, count}, ... } }
    → ward_price_history.json 形式に変換
    """
    by_ward = {}
    for ward_name, quarters in ward_data.items():
        by_ward[ward_name] = {
            "quarters": quarters,
        }

    return {
        "by_ward": by_ward,
        "data_source": "不動産情報ライブラリ（国土交通省）MCP API",
    }


def main():
    """ディレクトリ内のJSONファイルを処理して ward_price_history.json を生成。"""
    if len(sys.argv) < 2:
        print("usage: python3 collect_historical_prices.py <responses_dir>", file=sys.stderr)
        sys.exit(1)

    responses_dir = sys.argv[1]
    ward_data: Dict[str, Dict[str, dict]] = {}

    for fname in sorted(os.listdir(responses_dir)):
        if not fname.endswith(".json"):
            continue

        # ファイル名: 13101_2021Q2.json
        parts = fname.replace(".json", "").split("_")
        if len(parts) != 2:
            continue

        ward_code = parts[0]
        qlabel = parts[1]
        ward_name = WARD_CODE_TO_NAME.get(ward_code, ward_code)

        fpath = os.path.join(responses_dir, fname)
        with open(fpath, "r", encoding="utf-8") as f:
            data = json.load(f)

        m2_prices = compute_m2_prices_from_response(data)
        if not m2_prices:
            print(f"  {ward_name} {qlabel}: データなし", file=sys.stderr)
            continue

        if ward_name not in ward_data:
            ward_data[ward_name] = {}

        ward_data[ward_name][qlabel] = {
            "median_m2_price": round(statistics.median(m2_prices)),
            "mean_m2_price": round(statistics.mean(m2_prices)),
            "count": len(m2_prices),
        }
        print(f"  {ward_name} {qlabel}: 中央値 ¥{round(statistics.median(m2_prices)):,}/m² ({len(m2_prices)}件)", file=sys.stderr)

    result = build_history_from_data(ward_data)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
