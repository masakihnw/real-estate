#!/usr/bin/env python3
"""
e-Stat API から国勢調査の年齢3区分データを取得し、
東京23区の高齢化率（65歳以上人口割合）キャッシュを構築するバッチスクリプト。

対象データ: 国勢調査 5年ごと (2000, 2005, 2010, 2015, 2020)
出力:
  data/estat_aging.json — 全国・23区平均・区別の高齢化率推移

使い方:
  ESTAT_API_KEY=xxx python3 estat_aging_builder.py

環境変数:
  ESTAT_API_KEY  — e-Stat API のアプリケーションID（必須）
                   https://www.e-stat.go.jp/api/ から取得可能
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import requests

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------

ESTAT_API_BASE = "https://api.e-stat.go.jp/rest/3.0/app"
STATS_LIST_ENDPOINT = f"{ESTAT_API_BASE}/json/getStatsList"
STATS_DATA_ENDPOINT = f"{ESTAT_API_BASE}/json/getStatsData"

TOKYO_23_WARDS = [
    "千代田区", "中央区", "港区", "新宿区", "文京区",
    "台東区", "墨田区", "江東区", "品川区", "目黒区",
    "大田区", "世田谷区", "渋谷区", "中野区", "杉並区",
    "豊島区", "北区", "荒川区", "板橋区", "練馬区",
    "足立区", "葛飾区", "江戸川区",
]

TOKYO_23_AREA_CODES = [
    "13101", "13102", "13103", "13104", "13105",
    "13106", "13107", "13108", "13109", "13110",
    "13111", "13112", "13113", "13114", "13115",
    "13116", "13117", "13118", "13119", "13120",
    "13121", "13122", "13123",
]

NATIONAL_AREA_CODE = "00000"

# 国勢調査の年齢3区分・人口構成比テーブル (令和2年)
# cat03=3 → 65歳以上, cat01=0 → 国籍総数, cat02=0 → 男女総数
KNOWN_TABLE_2020 = "0003445165"

REQUEST_DELAY_SEC = 2

OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "data")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "estat_aging.json")

# 国勢調査から公表済みの全国高齢化率（65歳以上人口割合 %）
# 出典: 総務省統計局 国勢調査報告
NATIONAL_AGING_RATES = {
    "2000": 17.3,
    "2005": 20.2,
    "2010": 23.0,
    "2015": 26.6,
    "2020": 28.6,
}

# 国勢調査から公表済みの東京23区別・高齢化率（65歳以上人口割合 %）
# 出典: 総務省統計局 国勢調査、東京都総務局統計部
WARD_AGING_RATES: Dict[str, Dict[str, float]] = {
    "千代田区": {"2000": 17.0, "2005": 18.0, "2010": 19.3, "2015": 19.9, "2020": 18.9},
    "中央区":   {"2000": 19.5, "2005": 17.5, "2010": 16.2, "2015": 16.7, "2020": 16.3},
    "港区":     {"2000": 18.0, "2005": 17.7, "2010": 17.3, "2015": 17.9, "2020": 17.1},
    "新宿区":   {"2000": 16.8, "2005": 17.9, "2010": 19.2, "2015": 20.0, "2020": 19.3},
    "文京区":   {"2000": 16.6, "2005": 17.5, "2010": 18.7, "2015": 19.5, "2020": 18.9},
    "台東区":   {"2000": 22.2, "2005": 23.0, "2010": 23.7, "2015": 24.3, "2020": 23.9},
    "墨田区":   {"2000": 19.4, "2005": 20.8, "2010": 22.2, "2015": 23.2, "2020": 22.9},
    "江東区":   {"2000": 16.6, "2005": 18.0, "2010": 19.3, "2015": 21.0, "2020": 21.3},
    "品川区":   {"2000": 17.3, "2005": 18.6, "2010": 19.9, "2015": 21.2, "2020": 20.7},
    "目黒区":   {"2000": 15.5, "2005": 17.0, "2010": 18.6, "2015": 19.7, "2020": 19.3},
    "大田区":   {"2000": 17.6, "2005": 19.3, "2010": 21.2, "2015": 22.7, "2020": 22.8},
    "世田谷区": {"2000": 15.3, "2005": 16.7, "2010": 18.1, "2015": 19.6, "2020": 19.7},
    "渋谷区":   {"2000": 16.2, "2005": 17.3, "2010": 18.6, "2015": 19.1, "2020": 18.3},
    "中野区":   {"2000": 16.5, "2005": 18.6, "2010": 20.3, "2015": 21.2, "2020": 20.6},
    "杉並区":   {"2000": 16.3, "2005": 18.3, "2010": 20.0, "2015": 21.3, "2020": 20.9},
    "豊島区":   {"2000": 17.7, "2005": 19.0, "2010": 20.4, "2015": 20.7, "2020": 19.3},
    "北区":     {"2000": 21.0, "2005": 22.8, "2010": 24.3, "2015": 25.2, "2020": 25.0},
    "荒川区":   {"2000": 20.9, "2005": 22.1, "2010": 23.2, "2015": 24.1, "2020": 23.7},
    "板橋区":   {"2000": 17.0, "2005": 19.0, "2010": 21.0, "2015": 22.5, "2020": 22.6},
    "練馬区":   {"2000": 15.3, "2005": 17.7, "2010": 20.0, "2015": 22.0, "2020": 22.3},
    "足立区":   {"2000": 18.0, "2005": 20.5, "2010": 23.1, "2015": 25.2, "2020": 25.7},
    "葛飾区":   {"2000": 18.4, "2005": 20.5, "2010": 22.6, "2015": 24.2, "2020": 24.5},
    "江戸川区": {"2000": 14.3, "2005": 16.3, "2010": 18.5, "2015": 20.8, "2020": 21.5},
}

CENSUS_YEARS = ["2000", "2005", "2010", "2015", "2020"]


# ---------------------------------------------------------------------------
# API ヘルパー
# ---------------------------------------------------------------------------

def get_api_key() -> str:
    key = os.environ.get("ESTAT_API_KEY", "")
    if not key:
        print("エラー: ESTAT_API_KEY 環境変数を設定してください", file=sys.stderr)
        print("  https://www.e-stat.go.jp/api/ からアプリケーションIDを取得してください", file=sys.stderr)
        sys.exit(1)
    return key


def estat_request(endpoint: str, params: dict) -> Optional[dict]:
    try:
        resp = requests.get(endpoint, params=params, timeout=60)
        if resp.status_code == 200:
            return resp.json()
        else:
            print(f"  e-Stat API エラー: {resp.status_code}", file=sys.stderr)
            return None
    except Exception as e:
        print(f"  リクエスト例外: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# e-Stat API からの取得
# ---------------------------------------------------------------------------

def search_aging_table(api_key: str, census_year: str) -> Optional[str]:
    """指定した国勢調査年の年齢3区分構成比テーブルを検索。"""
    survey_year_map = {
        "2000": "200010",
        "2005": "200510",
        "2010": "201010",
        "2015": "201510",
        "2020": "202010",
    }
    survey_year = survey_year_map.get(census_year)
    if not survey_year:
        return None

    if census_year == "2020":
        return KNOWN_TABLE_2020

    params = {
        "appId": api_key,
        "searchWord": "国勢調査 年齢 3区分 人口構成比 市区町村",
        "surveyYears": survey_year,
        "limit": 50,
    }
    result = estat_request(STATS_LIST_ENDPOINT, params)
    if not result:
        return None

    tables = result.get("GET_STATS_LIST", {}).get("DATALIST_INF", {}).get("TABLE_INF", [])
    if isinstance(tables, dict):
        tables = [tables]

    for table in tables:
        title = table.get("TITLE", "")
        if isinstance(title, dict):
            title = title.get("$", "")
        title_spec = table.get("TITLE_SPEC", {})
        table_name = title_spec.get("TABLE_NAME", "")

        if "年齢" in table_name and ("3区分" in table_name or "３区分" in table_name):
            if "構成比" in table_name or "割合" in table_name:
                if "市区町村" in title or "市区町村" in table_name:
                    return table.get("@id")

    for table in tables:
        title = table.get("TITLE", "")
        if isinstance(title, dict):
            title = title.get("$", "")
        if "年齢" in title and "構成比" in title:
            return table.get("@id")

    return None


def fetch_aging_from_api(
    api_key: str, table_id: str
) -> Tuple[Optional[float], Dict[str, float]]:
    """
    指定テーブルから全国・23区の65歳以上構成比を取得。
    Returns: (national_rate, {ward_name: rate})
    """
    area_codes = ",".join([NATIONAL_AREA_CODE] + TOKYO_23_AREA_CODES)

    params = {
        "appId": api_key,
        "statsDataId": table_id,
        "cdArea": area_codes,
        "limit": 10000,
    }
    data = estat_request(STATS_DATA_ENDPOINT, params)
    if not data:
        return None, {}

    try:
        stat_data = data.get("GET_STATS_DATA", {})
        statistical_data = stat_data.get("STATISTICAL_DATA", {})
        data_inf = statistical_data.get("DATA_INF", {})
        values = data_inf.get("VALUE", [])

        if isinstance(values, dict):
            values = [values]
        if not values:
            return None, {}

        class_inf = statistical_data.get("CLASS_INF", {}).get("CLASS_OBJ", [])
        if isinstance(class_inf, dict):
            class_inf = [class_inf]

        area_map = {}
        cat_info: Dict[str, Dict[str, str]] = {}
        for cls in class_inf:
            cls_id = cls.get("@id", "")
            items = cls.get("CLASS", [])
            if isinstance(items, dict):
                items = [items]

            if cls_id == "area":
                for item in items:
                    area_map[item.get("@code", "")] = item.get("@name", "")
            elif cls_id.startswith("cat"):
                cat_info[cls_id] = {
                    item.get("@code", ""): item.get("@name", "")
                    for item in items
                }

        national_rate: Optional[float] = None
        ward_rates: Dict[str, float] = {}

        for val in values:
            area_code = val.get("@area", "")
            raw_value = val.get("$", "")

            cat_vals = {}
            for key in ["@cat01", "@cat02", "@cat03", "@cat04"]:
                if key in val:
                    cat_vals[key.replace("@", "")] = val[key]

            is_total_nationality = True
            is_total_sex = True
            is_65plus = False

            for cat_id, cat_code in cat_vals.items():
                cls_id = cat_id
                names = cat_info.get(cls_id, {})
                name = names.get(cat_code, "")

                if "国籍" in str(cat_info.get(cls_id, {}).values()):
                    if cat_code != "0":
                        is_total_nationality = False
                if "男" in name and "総数" not in name:
                    is_total_sex = False
                if "女" in name:
                    is_total_sex = False
                if "65歳以上" in name:
                    is_65plus = True

            if not is_65plus:
                continue

            try:
                rate = float(str(raw_value).replace(",", ""))
            except (ValueError, TypeError):
                continue

            if area_code == NATIONAL_AREA_CODE:
                if is_total_nationality and is_total_sex:
                    national_rate = rate
            else:
                area_name = area_map.get(area_code, "")
                for ward in TOKYO_23_WARDS:
                    if ward in area_name:
                        if is_total_nationality and is_total_sex:
                            ward_rates[ward] = rate
                        break

        return national_rate, ward_rates

    except Exception as e:
        print(f"  データ解析エラー: {e}", file=sys.stderr)
        return None, {}


def fetch_all_years(api_key: str) -> Tuple[Dict[str, float], Dict[str, Dict[str, float]]]:
    """
    全国勢調査年のデータを取得。API → フォールバックの順で試行。
    Returns: (national_by_year, ward_rates_by_year[ward][year])
    """
    national_by_year: Dict[str, float] = {}
    ward_by_year: Dict[str, Dict[str, float]] = {w: {} for w in TOKYO_23_WARDS}

    for year in CENSUS_YEARS:
        print(f"\n--- {year}年 国勢調査 ---", file=sys.stderr)

        table_id = search_aging_table(api_key, year)
        api_national = None
        api_wards: Dict[str, float] = {}

        if table_id:
            print(f"  テーブル {table_id} からデータ取得中...", file=sys.stderr)
            api_national, api_wards = fetch_aging_from_api(api_key, table_id)
            time.sleep(REQUEST_DELAY_SEC)

            if api_national is not None:
                print(f"  全国: {api_national}%", file=sys.stderr)
                national_by_year[year] = round(api_national, 1)
            if api_wards:
                print(f"  {len(api_wards)}区のデータを取得", file=sys.stderr)
                for ward, rate in api_wards.items():
                    ward_by_year[ward][year] = round(rate, 1)

        if year not in national_by_year:
            fallback = NATIONAL_AGING_RATES.get(year)
            if fallback is not None:
                print(f"  全国: フォールバックデータ使用 ({fallback}%)", file=sys.stderr)
                national_by_year[year] = fallback

        for ward in TOKYO_23_WARDS:
            if year not in ward_by_year.get(ward, {}):
                fallback = WARD_AGING_RATES.get(ward, {}).get(year)
                if fallback is not None:
                    ward_by_year[ward][year] = fallback

    return national_by_year, ward_by_year


# ---------------------------------------------------------------------------
# JSON 構築
# ---------------------------------------------------------------------------

def build_output(
    national_by_year: Dict[str, float],
    ward_by_year: Dict[str, Dict[str, float]],
) -> dict:
    national_history = [
        {"year": y, "aging_rate": national_by_year[y]}
        for y in sorted(national_by_year.keys())
    ]

    by_ward: Dict[str, Any] = {}
    all_ward_rates_by_year: Dict[str, List[float]] = {y: [] for y in CENSUS_YEARS}

    for ward in TOKYO_23_WARDS:
        rates = ward_by_year.get(ward, {})
        history = [
            {"year": y, "aging_rate": rates[y]}
            for y in sorted(rates.keys())
            if y in rates
        ]
        latest = max(rates.keys(), default=None)
        by_ward[ward] = {
            "aging_rate_history": history,
            "latest_aging_rate": rates.get(latest) if latest else None,
        }
        for y in CENSUS_YEARS:
            if y in rates:
                all_ward_rates_by_year[y].append(rates[y])

    tokyo23_avg_history = []
    for y in sorted(CENSUS_YEARS):
        rates = all_ward_rates_by_year[y]
        if rates:
            avg = round(sum(rates) / len(rates), 1)
            tokyo23_avg_history.append({"year": y, "aging_rate": avg})

    return {
        "national_aging_history": national_history,
        "tokyo23_avg_aging_history": tokyo23_avg_history,
        "by_ward": by_ward,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "data_source": "e-Stat 国勢調査（総務省）",
    }


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="e-Stat 国勢調査から東京23区の高齢化率キャッシュを構築"
    )
    ap.add_argument(
        "--output-dir",
        default=OUTPUT_DIR,
        help=f"出力ディレクトリ (デフォルト: {OUTPUT_DIR})",
    )
    ap.add_argument(
        "--fallback-only",
        action="store_true",
        help="API を使わずフォールバックデータのみで構築",
    )
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    print("=== e-Stat 高齢化率キャッシュ構築開始 ===", file=sys.stderr)

    if args.fallback_only:
        print("フォールバックモード: API をスキップ", file=sys.stderr)
        national_by_year = dict(NATIONAL_AGING_RATES)
        ward_by_year = {
            ward: dict(rates) for ward, rates in WARD_AGING_RATES.items()
        }
    else:
        api_key = get_api_key()
        national_by_year, ward_by_year = fetch_all_years(api_key)

    result = build_output(national_by_year, ward_by_year)

    output_path = os.path.join(args.output_dir, "estat_aging.json")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    ward_count = len([
        w for w in result.get("by_ward", {}).values()
        if w.get("latest_aging_rate") is not None
    ])
    print(f"\n=== 完了: 全国 + {ward_count}区の高齢化率データを保存 ===", file=sys.stderr)
    print(f"出力: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
