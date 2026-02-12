#!/usr/bin/env python3
"""
e-Stat API から東京23区の人口動態データを取得し、
エリアスコアリング用のキャッシュを構築するバッチスクリプト。

年1回実行。
出力:
  data/estat_population.json — 区別人口推移・世帯数推移

使い方:
  ESTAT_API_KEY=xxx python3 estat_population_builder.py

環境変数:
  ESTAT_API_KEY  — e-Stat API のアプリケーションID（必須）
                   https://www.e-stat.go.jp/api/ から取得可能

※ e-Stat API の利用は無料。アプリケーションIDの登録が必要。
"""

import argparse
import json
import os
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Optional

import requests

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------

ESTAT_API_BASE = "https://api.e-stat.go.jp/rest/3.0/app"
STATS_LIST_ENDPOINT = f"{ESTAT_API_BASE}/json/getStatsList"
STATS_DATA_ENDPOINT = f"{ESTAT_API_BASE}/json/getStatsData"

# 住民基本台帳人口移動報告の統計表ID
# 東京都特別区の人口・世帯数（住民基本台帳ベース）
# 統計ID: 000200241 (住民基本台帳に基づく人口、人口動態及び世帯数)
STATS_ID = "000200241"

# 東京23区の区名 → コードマッピング（e-Stat の地域コード）
TOKYO_23_WARDS = [
    "千代田区", "中央区", "港区", "新宿区", "文京区",
    "台東区", "墨田区", "江東区", "品川区", "目黒区",
    "大田区", "世田谷区", "渋谷区", "中野区", "杉並区",
    "豊島区", "北区", "荒川区", "板橋区", "練馬区",
    "足立区", "葛飾区", "江戸川区",
]

# API リクエスト間隔（秒）
REQUEST_DELAY_SEC = 2

# 出力先
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "data")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, "estat_population.json")


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
    """e-Stat API リクエストを送信。"""
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
# 人口データ取得（住民基本台帳ベース）
# ---------------------------------------------------------------------------

def search_population_stats(api_key: str) -> List[dict]:
    """
    住民基本台帳に基づく人口統計の統計表一覧を検索。
    """
    params = {
        "appId": api_key,
        "searchWord": "住民基本台帳 人口 東京都 特別区",
        "surveyYears": "",
        "limit": 100,
    }
    result = estat_request(STATS_LIST_ENDPOINT, params)
    if not result:
        return []

    tables = []
    try:
        table_inf = result.get("GET_STATS_LIST", {}).get("DATALIST_INF", {}).get("TABLE_INF", [])
        if isinstance(table_inf, dict):
            table_inf = [table_inf]
        for table in table_inf:
            table_id = table.get("@id", "")
            title = table.get("TITLE", "")
            if isinstance(title, dict):
                title = title.get("$", "")
            cycle = table.get("CYCLE", "")
            tables.append({
                "id": table_id,
                "title": title,
                "cycle": cycle,
            })
    except Exception as e:
        print(f"  統計表解析エラー: {e}", file=sys.stderr)

    return tables


def fetch_population_data(api_key: str) -> dict:
    """
    東京23区の人口データを取得。
    複数の手法で取得を試みる。
    """
    current_year = datetime.now().year

    # 東京都の区別人口を直接収集するためのフォールバック
    # 総務省統計局の住民基本台帳人口データを使用
    result_by_ward: Dict[str, Any] = {}

    # まず統計表一覧を検索
    print("  統計表を検索中...", file=sys.stderr)
    tables = search_population_stats(api_key)
    print(f"  {len(tables)} 件の統計表が見つかりました", file=sys.stderr)

    # 東京都の区別人口に関する統計表を探す
    target_tables = []
    for table in tables:
        title = table.get("title", "").lower()
        if "人口" in title and ("市区町村" in title or "特別区" in title or "東京" in title):
            target_tables.append(table)

    if not target_tables:
        print("  適切な統計表が見つかりませんでした。手動でデータを入力する必要があります。", file=sys.stderr)
        # フォールバック: 推計データを使用
        return build_estimated_population()

    # 最初の適切な統計表からデータを取得
    for table in target_tables[:3]:  # 最大3テーブルを試行
        table_id = table["id"]
        print(f"  統計表 {table_id}: {table['title']} を取得中...", file=sys.stderr)

        params = {
            "appId": api_key,
            "statsDataId": table_id,
            "cdArea": "13101,13102,13103,13104,13105,13106,13107,13108,"
                      "13109,13110,13111,13112,13113,13114,13115,13116,"
                      "13117,13118,13119,13120,13121,13122,13123",
            "limit": 10000,
        }
        data = estat_request(STATS_DATA_ENDPOINT, params)
        time.sleep(REQUEST_DELAY_SEC)

        if not data:
            continue

        try:
            stat_data = data.get("GET_STATS_DATA", {})
            data_inf = stat_data.get("STATISTICAL_DATA", {}).get("DATA_INF", {})
            values = data_inf.get("VALUE", [])

            if isinstance(values, dict):
                values = [values]

            if not values:
                continue

            # データを解析
            class_inf = stat_data.get("STATISTICAL_DATA", {}).get("CLASS_INF", {}).get("CLASS_OBJ", [])
            if isinstance(class_inf, dict):
                class_inf = [class_inf]

            # 地域コード → 区名の対応表を構築
            area_map = {}
            time_map = {}
            cat_map = {}

            for cls in class_inf:
                cls_id = cls.get("@id", "")
                class_items = cls.get("CLASS", [])
                if isinstance(class_items, dict):
                    class_items = [class_items]

                if "area" in cls_id.lower():
                    for item in class_items:
                        code = item.get("@code", "")
                        name = item.get("@name", "")
                        area_map[code] = name
                elif "time" in cls_id.lower():
                    for item in class_items:
                        code = item.get("@code", "")
                        name = item.get("@name", "")
                        time_map[code] = name
                elif "cat" in cls_id.lower():
                    for item in class_items:
                        code = item.get("@code", "")
                        name = item.get("@name", "")
                        cat_map[code] = name

            # 値を区別に集計
            for val in values:
                area_code = val.get("@area", "")
                time_code = val.get("@time", "")
                cat_code = val.get("@cat01", "")
                value = val.get("$", "")

                area_name = area_map.get(area_code, "")
                cat_name = cat_map.get(cat_code, "")

                # 23区のデータのみ
                ward_name = None
                for w in TOKYO_23_WARDS:
                    if w in area_name:
                        ward_name = w
                        break
                if not ward_name:
                    continue

                if ward_name not in result_by_ward:
                    result_by_ward[ward_name] = {"population": {}, "households": {}}

                try:
                    num_value = int(str(value).replace(",", ""))
                except (ValueError, TypeError):
                    continue

                # 年を抽出
                year_str = time_code[:4] if len(time_code) >= 4 else time_code

                if "人口" in cat_name and "世帯" not in cat_name:
                    result_by_ward[ward_name]["population"][year_str] = num_value
                elif "世帯" in cat_name:
                    result_by_ward[ward_name]["households"][year_str] = num_value

            if result_by_ward:
                print(f"  {len(result_by_ward)} 区のデータを取得しました", file=sys.stderr)
                break

        except Exception as e:
            print(f"  データ解析エラー: {e}", file=sys.stderr)
            continue

    if not result_by_ward:
        print("  API からデータを取得できませんでした。推計データを使用します。", file=sys.stderr)
        return build_estimated_population()

    # 変動率を算出
    ward_summary = {}
    for ward_name, ward_data in result_by_ward.items():
        pop = ward_data.get("population", {})
        households = ward_data.get("households", {})

        pop_years = sorted(pop.keys())
        hh_years = sorted(households.keys())

        # 5年間の人口変動率
        pop_change_5yr = None
        if len(pop_years) >= 2:
            oldest = pop[pop_years[0]]
            latest = pop[pop_years[-1]]
            if oldest > 0:
                pop_change_5yr = round((latest - oldest) / oldest * 100, 2)

        # 直近1年の人口変動率
        pop_change_1yr = None
        if len(pop_years) >= 2:
            prev = pop[pop_years[-2]]
            latest = pop[pop_years[-1]]
            if prev > 0:
                pop_change_1yr = round((latest - prev) / prev * 100, 2)

        ward_summary[ward_name] = {
            "latest_population": pop.get(pop_years[-1]) if pop_years else None,
            "latest_households": households.get(hh_years[-1]) if hh_years else None,
            "pop_change_1yr_pct": pop_change_1yr,
            "pop_change_5yr_pct": pop_change_5yr,
            "population_history": [
                {"year": y, "population": pop[y]} for y in pop_years
            ],
            "household_history": [
                {"year": y, "households": households[y]} for y in hh_years
            ],
        }

    return {
        "by_ward": ward_summary,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "data_source": "e-Stat 政府統計（総務省）",
    }


def build_estimated_population() -> dict:
    """
    API からデータが取得できない場合のフォールバック。
    手動で後から更新可能な空のスキーマを構築。
    """
    ward_summary = {}
    for ward_name in TOKYO_23_WARDS:
        ward_summary[ward_name] = {
            "latest_population": None,
            "latest_households": None,
            "pop_change_1yr_pct": None,
            "pop_change_5yr_pct": None,
            "population_history": [],
            "household_history": [],
            "note": "API から取得できませんでした。手動データ入力が必要です。",
        }

    return {
        "by_ward": ward_summary,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "data_source": "e-Stat 政府統計（総務省）",
        "note": "フォールバック: 空のスキーマ。API キーと統計表IDを確認してください。",
    }


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="e-Stat API から東京23区の人口動態キャッシュを構築"
    )
    ap.add_argument(
        "--output-dir",
        default=OUTPUT_DIR,
        help=f"出力ディレクトリ (デフォルト: {OUTPUT_DIR})",
    )
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    api_key = get_api_key()
    print("=== e-Stat 人口動態キャッシュ構築開始 ===", file=sys.stderr)

    result = fetch_population_data(api_key)

    output_path = os.path.join(args.output_dir, "estat_population.json")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    ward_count = len([
        w for w in result.get("by_ward", {}).values()
        if w.get("latest_population") is not None
    ])
    print(f"=== 完了: {ward_count}区の人口データを保存 ===", file=sys.stderr)
    print(f"出力: {output_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
