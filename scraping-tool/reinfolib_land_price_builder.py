#!/usr/bin/env python3
"""
不動産情報ライブラリ API から地価公示・地価調査データを取得し、
エリア別の地価変動率キャッシュを構築するバッチスクリプト。

年1回実行（地価公示は毎年3月公表）。
出力:
  data/reinfolib_land_prices.json — 区別の地価公示変動率

使い方:
  REINFOLIB_API_KEY=xxx python3 reinfolib_land_price_builder.py

環境変数:
  REINFOLIB_API_KEY  — 不動産情報ライブラリ API のサブスクリプションキー（必須）
"""

import argparse
import json
import os
import statistics
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import requests

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------

API_BASE = "https://www.reinfolib.mlit.go.jp/ex-api/external"
# 鑑定評価書情報 API（区別に地価公示データを取得）
APPRAISAL_ENDPOINT = f"{API_BASE}/XCT001"

# 東京都コード
TOKYO_AREA_CODE = "13"

# 区コード → 区名マッピング
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

# API リクエスト間隔（秒）
REQUEST_DELAY_SEC = 2

# 出力先
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "data")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "reinfolib_land_prices.json")


# ---------------------------------------------------------------------------
# API ヘルパー
# ---------------------------------------------------------------------------

def get_api_key() -> str:
    key = os.environ.get("REINFOLIB_API_KEY", "")
    if not key:
        print("エラー: REINFOLIB_API_KEY 環境変数を設定してください", file=sys.stderr)
        sys.exit(1)
    return key


def api_request(endpoint: str, params: dict, api_key: str) -> Optional[dict]:
    headers = {"Ocp-Apim-Subscription-Key": api_key}
    try:
        resp = requests.get(endpoint, headers=headers, params=params, timeout=60)
        if resp.status_code == 200:
            return resp.json()
        else:
            print(f"  API エラー: {resp.status_code} params={params}", file=sys.stderr)
            return None
    except Exception as e:
        print(f"  リクエスト例外: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# データ取得
# ---------------------------------------------------------------------------

def fetch_land_prices(api_key: str) -> dict:
    """
    東京都の住宅地・商業地の地価公示データを取得。
    直近5年分の鑑定評価書情報から変動率を算出。
    """
    current_year = datetime.now().year
    # XCT001 は直近5年分のみ取得可能
    years = list(range(max(current_year - 4, 2021), current_year + 1))

    # division: 00=住宅地, 05=商業地
    divisions = {"residential": "00", "commercial": "05"}

    result_by_ward: Dict[str, Any] = {}

    for div_name, div_code in divisions.items():
        for year in years:
            print(f"  地価公示取得: {year}年 {div_name}...", file=sys.stderr)
            data = api_request(
                APPRAISAL_ENDPOINT,
                {"year": year, "area": TOKYO_AREA_CODE, "division": div_code},
                api_key,
            )
            if not data:
                time.sleep(REQUEST_DELAY_SEC)
                continue

            # 鑑定評価書データを区ごとに集計
            items = data.get("data", data) if isinstance(data, dict) else data
            if isinstance(items, dict):
                items = items.get("data", [])
            if not isinstance(items, list):
                time.sleep(REQUEST_DELAY_SEC)
                continue

            for item in items:
                # 市区町村コードを取得
                ward_code = None
                try:
                    # 鑑定評価書のフィールド名は長い日本語名
                    # 標準地番号の市区町村コードを探す
                    for key in item:
                        if "市区町村コード" in str(key) and "県" not in str(key):
                            raw = item[key]
                            if raw:
                                ward_code = str(raw).strip()
                                # 5桁に正規化
                                if len(ward_code) < 5:
                                    ward_code = ward_code.zfill(5)
                                break
                except Exception:
                    continue

                if not ward_code or ward_code not in WARD_CODE_TO_NAME:
                    continue

                ward_name = WARD_CODE_TO_NAME[ward_code]
                if ward_name not in result_by_ward:
                    result_by_ward[ward_name] = {
                        "ward_code": ward_code,
                        "residential": {},
                        "commercial": {},
                    }

                # 価格と変動率を取得
                price = None
                change_rate = None
                for key, val in item.items():
                    if "1㎡当たりの価格" in str(key) or "当年価格" in str(key):
                        try:
                            price = int(str(val).replace(",", ""))
                        except (ValueError, TypeError):
                            pass
                    if "変動率" in str(key):
                        try:
                            change_rate = float(str(val).replace(",", ""))
                        except (ValueError, TypeError):
                            pass

                if price:
                    yearly_data = result_by_ward[ward_name][div_name]
                    if str(year) not in yearly_data:
                        yearly_data[str(year)] = {
                            "prices": [],
                            "change_rates": [],
                        }
                    yearly_data[str(year)]["prices"].append(price)
                    if change_rate is not None:
                        yearly_data[str(year)]["change_rates"].append(change_rate)

            time.sleep(REQUEST_DELAY_SEC)

    # 集計: 区ごとの中央値・平均変動率
    land_prices: Dict[str, Any] = {}
    for ward_name, ward_data in result_by_ward.items():
        ward_result: Dict[str, Any] = {"ward_code": ward_data["ward_code"]}

        for div_name in ["residential", "commercial"]:
            div_data = ward_data.get(div_name, {})
            yearly_summary = []

            for year_str in sorted(div_data.keys()):
                yd = div_data[year_str]
                prices = yd.get("prices", [])
                rates = yd.get("change_rates", [])

                summary: Dict[str, Any] = {"year": int(year_str)}
                if prices:
                    summary["median_price_m2"] = round(statistics.median(prices))
                    summary["count"] = len(prices)
                else:
                    summary["median_price_m2"] = None
                    summary["count"] = 0
                if rates:
                    summary["avg_change_rate"] = round(statistics.mean(rates), 2)
                else:
                    summary["avg_change_rate"] = None

                yearly_summary.append(summary)

            ward_result[div_name] = yearly_summary

            # 直近の変動率
            latest = yearly_summary[-1] if yearly_summary else {}
            ward_result[f"{div_name}_latest_change_rate"] = latest.get("avg_change_rate")

        land_prices[ward_name] = ward_result

    return {
        "by_ward": land_prices,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "data_source": "不動産情報ライブラリ 鑑定評価書情報（国土交通省）",
    }


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="不動産情報ライブラリ API から地価公示キャッシュを構築"
    )
    ap.add_argument(
        "--output-dir",
        default=OUTPUT_DIR,
        help=f"出力ディレクトリ (デフォルト: {OUTPUT_DIR})",
    )
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    api_key = get_api_key()
    print("=== 地価公示キャッシュ構築開始 ===", file=sys.stderr)

    result = fetch_land_prices(api_key)

    output_path = os.path.join(args.output_dir, "reinfolib_land_prices.json")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    ward_count = len(result.get("by_ward", {}))
    print(f"=== 完了: {ward_count}区の地価データを保存 ===", file=sys.stderr)
    print(f"出力: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
