#!/usr/bin/env python3
"""
不動産情報ライブラリ API から成約価格・取引価格データを取得し、
エリア別の相場キャッシュを構築するバッチスクリプト。

四半期に1回実行（GitHub Actions から cron で起動）。
出力:
  data/reinfolib_prices.json          — 区別・駅別の直近m²単価中央値
  data/reinfolib_trends.json          — 区別の四半期別m²単価推移（過去5年）
  data/reinfolib_raw_transactions.json — 直近4四半期の個別取引レコード
                                         （段階的マッチング・同一マンション事例用）

使い方:
  REINFOLIB_API_KEY=xxx python3 reinfolib_cache_builder.py

環境変数:
  REINFOLIB_API_KEY  — 不動産情報ライブラリ API のサブスクリプションキー（必須）
"""

import argparse
import json
import os
import re
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
CITY_LIST_ENDPOINT = f"{API_BASE}/XIT002"
PRICE_ENDPOINT = f"{API_BASE}/XIT001"

# 東京都コード
TOKYO_AREA_CODE = "13"

# 東京23区の市区町村コード (13101〜13123)
TOKYO_23_WARD_CODES = [str(code) for code in range(13101, 13124)]

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

# 取得する年数（過去5年分）
YEARS_BACK = 5

# API リクエスト間隔（秒）
REQUEST_DELAY_SEC = 2

# 出力先
OUTPUT_DIR = os.path.join(os.path.dirname(__file__), "data")
PRICES_OUTPUT = os.path.join(OUTPUT_DIR, "reinfolib_prices.json")
TRENDS_OUTPUT = os.path.join(OUTPUT_DIR, "reinfolib_trends.json")
RAW_TRANSACTIONS_OUTPUT = os.path.join(OUTPUT_DIR, "reinfolib_raw_transactions.json")


# ---------------------------------------------------------------------------
# API ヘルパー
# ---------------------------------------------------------------------------

def get_api_key() -> str:
    """環境変数から API キーを取得。"""
    key = os.environ.get("REINFOLIB_API_KEY", "")
    if not key:
        print("エラー: REINFOLIB_API_KEY 環境変数を設定してください", file=sys.stderr)
        sys.exit(1)
    return key


def api_request(endpoint: str, params: dict, api_key: str) -> Optional[dict]:
    """API リクエストを送信し、JSON を返す。"""
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

def get_target_periods() -> List[Tuple[int, Optional[int]]]:
    """取得対象の (year, quarter) リストを返す。quarter=None は年単位。"""
    current_year = datetime.now().year
    periods = []
    for year in range(current_year - YEARS_BACK, current_year + 1):
        for quarter in range(1, 5):
            # 未来の四半期はスキップ
            if year == current_year:
                current_quarter = (datetime.now().month - 1) // 3 + 1
                if quarter > current_quarter:
                    continue
            periods.append((year, quarter))
    return periods


def quarter_label(year: int, quarter: int) -> str:
    """四半期ラベル (例: '2024Q3')。"""
    return f"{year}Q{quarter}"


def fetch_ward_prices(
    ward_code: str,
    year: int,
    quarter: int,
    api_key: str,
    price_classification: str = "02",  # 02=成約価格, 01=取引価格
) -> List[dict]:
    """指定区・四半期の中古マンション取引データを取得。"""
    params = {
        "year": year,
        "quarter": quarter,
        "city": ward_code,
        "priceClassification": price_classification,
    }
    result = api_request(PRICE_ENDPOINT, params, api_key)
    if result is None:
        return []

    data = result.get("data", [])

    # 中古マンション等のみフィルタ (Type に "中古マンション等" を含む)
    mansion_data = []
    for item in data:
        item_type = item.get("Type", "")
        if "中古マンション" in item_type:
            mansion_data.append(item)

    return mansion_data


def parse_m2_price(item: dict) -> Optional[float]:
    """取引データから m² 単価を算出。"""
    try:
        trade_price = item.get("TradePrice")
        area = item.get("Area")
        if trade_price and area:
            price = float(str(trade_price).replace(",", ""))
            area_val = float(str(area).replace(",", ""))
            if area_val > 0:
                return price / area_val
    except (ValueError, TypeError):
        pass
    return None


def parse_floor_plan(item: dict) -> Optional[str]:
    """間取り情報を取得。"""
    return item.get("FloorPlan")


def parse_area(item: dict) -> Optional[float]:
    """面積を取得。"""
    try:
        area = item.get("Area")
        if area:
            return float(str(area).replace(",", ""))
    except (ValueError, TypeError):
        pass
    return None


def parse_trade_price(item: dict) -> Optional[int]:
    """取引価格（円）を取得。"""
    try:
        tp = item.get("TradePrice")
        if tp:
            return int(float(str(tp).replace(",", "")))
    except (ValueError, TypeError):
        pass
    return None


def parse_building_year(year_str: Optional[str]) -> Optional[int]:
    """'2014年' → 2014 のように築年を数値化。"""
    if not year_str:
        return None
    m = re.search(r"(\d{4})", year_str)
    if m:
        return int(m.group(1))
    return None


# 全角→半角変換テーブル
_FULLWIDTH_TO_HALFWIDTH = str.maketrans(
    "０１２３４５６７８９"
    "ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ"
    "ａｂｃｄｅｆｇｈｉｊｋｌｍｎｏｐｑｒｓｔｕｖｗｘｙｚ"
    "＋",
    "0123456789"
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    "abcdefghijklmnopqrstuvwxyz"
    "+",
)


def normalize_text(text: str) -> str:
    """全角英数字を半角に変換し、前後の空白を除去。"""
    return text.translate(_FULLWIDTH_TO_HALFWIDTH).strip()


def parse_raw_transaction(
    item: dict,
    ward_name: str,
    ward_code: str,
    period_label: str,
) -> Optional[dict]:
    """
    API レスポンスの1件を正規化された取引レコードに変換。
    enricher での段階的マッチング・同一マンション事例用。
    """
    trade_price = parse_trade_price(item)
    area = parse_area(item)
    if not trade_price or not area or area <= 0:
        return None

    floor_plan_raw = item.get("FloorPlan", "")
    floor_plan = normalize_text(floor_plan_raw) if floor_plan_raw else ""
    structure_raw = item.get("Structure", "")
    structure = normalize_text(structure_raw) if structure_raw else ""

    return {
        "ward": ward_name,
        "ward_code": ward_code,
        "district_name": item.get("DistrictName", ""),
        "district_code": item.get("DistrictCode", ""),
        "trade_price": trade_price,
        "area": area,
        "m2_price": round(trade_price / area),
        "floor_plan": floor_plan,
        "building_year": parse_building_year(item.get("BuildingYear")),
        "structure": structure,
        "period": period_label,
    }


# ---------------------------------------------------------------------------
# キャッシュ構築
# ---------------------------------------------------------------------------

def build_prices_and_trends(api_key: str) -> Tuple[dict, dict, dict]:
    """
    全23区 × 全四半期のデータを取得し、prices・trends・raw_transactions を構築。

    prices:           区別の直近相場（enricher 用）
    trends:           区別の四半期推移（iOS チャート用）
    raw_transactions: 直近4四半期の個別取引レコード（段階的マッチング・同一棟事例用）
    """
    periods = get_target_periods()
    print(f"対象期間: {len(periods)} 四半期", file=sys.stderr)

    # ward_code → quarter_label → [m2_prices]
    all_data: Dict[str, Dict[str, List[float]]] = {}
    # ward_code → quarter_label → sample_count
    sample_counts: Dict[str, Dict[str, int]] = {}
    # ward_code → quarter_label → [raw API items] (直近4四半期のみ)
    all_raw_items: Dict[str, Dict[str, List[dict]]] = {}

    # 直近4四半期のラベルを先に計算（生データ保存対象の判定用）
    recent_periods = periods[-4:] if len(periods) >= 4 else periods
    recent_qlabels_set = set(quarter_label(y, q) for y, q in recent_periods)

    for ward_code in TOKYO_23_WARD_CODES:
        ward_name = WARD_CODE_TO_NAME.get(ward_code, ward_code)
        all_data[ward_code] = {}
        sample_counts[ward_code] = {}
        all_raw_items[ward_code] = {}

        for year, quarter in periods:
            qlabel = quarter_label(year, quarter)

            # 成約価格 (priceClassification=02) を優先取得
            items = fetch_ward_prices(ward_code, year, quarter, api_key, "02")

            # 成約価格が少ない場合は取引価格も追加
            if len(items) < 3:
                items_01 = fetch_ward_prices(ward_code, year, quarter, api_key, "01")
                # 重複を避けるため取引価格を追加（成約データがない四半期の補完）
                if not items:
                    items = items_01

            m2_prices = []
            for item in items:
                p = parse_m2_price(item)
                if p is not None and p > 0:
                    m2_prices.append(p)

            all_data[ward_code][qlabel] = m2_prices
            sample_counts[ward_code][qlabel] = len(m2_prices)

            # 直近4四半期の生データを保存
            if qlabel in recent_qlabels_set:
                all_raw_items[ward_code][qlabel] = items

            time.sleep(REQUEST_DELAY_SEC)

        print(f"  {ward_name}: {sum(len(v) for v in all_data[ward_code].values())} 件取得", file=sys.stderr)

    # --- prices.json 構築 ---
    # 直近4四半期の中央値を算出
    recent_periods = periods[-4:] if len(periods) >= 4 else periods
    recent_qlabels = [quarter_label(y, q) for y, q in recent_periods]

    prices_by_ward: Dict[str, Any] = {}
    for ward_code in TOKYO_23_WARD_CODES:
        ward_name = WARD_CODE_TO_NAME.get(ward_code, ward_code)

        # 直近4四半期を統合
        recent_m2_prices = []
        for ql in recent_qlabels:
            recent_m2_prices.extend(all_data[ward_code].get(ql, []))

        if recent_m2_prices:
            median_m2 = round(statistics.median(recent_m2_prices))
            mean_m2 = round(statistics.mean(recent_m2_prices))
        else:
            median_m2 = None
            mean_m2 = None

        # 四半期別の中央値（直近4四半期）
        quarterly = {}
        for ql in recent_qlabels:
            qprices = all_data[ward_code].get(ql, [])
            if qprices:
                quarterly[ql] = {
                    "median_m2_price": round(statistics.median(qprices)),
                    "count": len(qprices),
                }

        prices_by_ward[ward_name] = {
            "ward_code": ward_code,
            "median_m2_price": median_m2,
            "mean_m2_price": mean_m2,
            "sample_count": len(recent_m2_prices),
            "quarterly": quarterly,
        }

    prices = {
        "by_ward": prices_by_ward,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "periods_covered": [quarter_label(y, q) for y, q in recent_periods],
        "data_source": "不動産情報ライブラリ（国土交通省）",
    }

    # --- trends.json 構築 ---
    trends_by_ward: Dict[str, Any] = {}
    all_qlabels = [quarter_label(y, q) for y, q in periods]

    for ward_code in TOKYO_23_WARD_CODES:
        ward_name = WARD_CODE_TO_NAME.get(ward_code, ward_code)

        quarters_data = []
        for ql in all_qlabels:
            qprices = all_data[ward_code].get(ql, [])
            if qprices:
                quarters_data.append({
                    "quarter": ql,
                    "median_m2_price": round(statistics.median(qprices)),
                    "mean_m2_price": round(statistics.mean(qprices)),
                    "count": len(qprices),
                })
            else:
                quarters_data.append({
                    "quarter": ql,
                    "median_m2_price": None,
                    "mean_m2_price": None,
                    "count": 0,
                })

        # YoY 変動率（4四半期前と比較）
        for i, qd in enumerate(quarters_data):
            if i >= 4 and qd["median_m2_price"] and quarters_data[i - 4]["median_m2_price"]:
                prev = quarters_data[i - 4]["median_m2_price"]
                curr = qd["median_m2_price"]
                qd["yoy_change_pct"] = round((curr - prev) / prev * 100, 1)
            else:
                qd["yoy_change_pct"] = None

        trends_by_ward[ward_name] = {
            "ward_code": ward_code,
            "quarters": quarters_data,
        }

    trends = {
        "by_ward": trends_by_ward,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "periods": all_qlabels,
        "data_source": "不動産情報ライブラリ（国土交通省）",
    }

    # --- raw_transactions.json 構築 ---
    # 直近4四半期の個別取引レコードを正規化して保存
    raw_transaction_list: List[dict] = []
    for ward_code in TOKYO_23_WARD_CODES:
        ward_name = WARD_CODE_TO_NAME.get(ward_code, ward_code)
        for qlabel in sorted(recent_qlabels_set):
            items = all_raw_items.get(ward_code, {}).get(qlabel, [])
            for item in items:
                rec = parse_raw_transaction(item, ward_name, ward_code, qlabel)
                if rec is not None:
                    raw_transaction_list.append(rec)

    raw_transactions = {
        "transactions": raw_transaction_list,
        "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        "periods_covered": sorted(recent_qlabels_set),
        "data_source": "不動産情報ライブラリ（国土交通省）",
        "record_count": len(raw_transaction_list),
    }

    return prices, trends, raw_transactions


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="不動産情報ライブラリ API から成約価格キャッシュを構築"
    )
    ap.add_argument(
        "--output-dir",
        default=OUTPUT_DIR,
        help=f"出力ディレクトリ (デフォルト: {OUTPUT_DIR})",
    )
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    api_key = get_api_key()
    print("=== 不動産情報ライブラリ キャッシュ構築開始 ===", file=sys.stderr)
    print(f"出力先: {args.output_dir}", file=sys.stderr)

    prices, trends, raw_transactions = build_prices_and_trends(api_key)

    prices_path = os.path.join(args.output_dir, "reinfolib_prices.json")
    trends_path = os.path.join(args.output_dir, "reinfolib_trends.json")
    raw_tx_path = os.path.join(args.output_dir, "reinfolib_raw_transactions.json")

    with open(prices_path, "w", encoding="utf-8") as f:
        json.dump(prices, f, ensure_ascii=False, indent=2)
    print(f"prices キャッシュ保存: {prices_path}", file=sys.stderr)

    with open(trends_path, "w", encoding="utf-8") as f:
        json.dump(trends, f, ensure_ascii=False, indent=2)
    print(f"trends キャッシュ保存: {trends_path}", file=sys.stderr)

    with open(raw_tx_path, "w", encoding="utf-8") as f:
        json.dump(raw_transactions, f, ensure_ascii=False, indent=2)
    print(
        f"raw_transactions キャッシュ保存: {raw_tx_path}"
        f" ({raw_transactions['record_count']} 件)",
        file=sys.stderr,
    )

    # サマリー出力
    ward_count = len(prices["by_ward"])
    total_samples = sum(
        w.get("sample_count", 0) for w in prices["by_ward"].values()
    )
    print(
        f"=== 完了: {ward_count}区, 合計 {total_samples} 件"
        f" (個別レコード {raw_transactions['record_count']} 件) ===",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
