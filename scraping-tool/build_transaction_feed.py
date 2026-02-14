#!/usr/bin/env python3
"""
首都圏（1都3県）の成約実績データを取得・フィルタ・ジオコード・集約して
iOS アプリ向け transactions.json を生成するバッチスクリプト。

処理フロー:
  1. shutoken_city_codes.json から市区町村コードをロード
  2. reinfolib API で成約データを取得（中古マンション等、直近4四半期）
  3. config.py の購入条件でフィルタ（価格・面積・間取り・築年）
  4. 町丁目レベルでジオコーディング（geocode_cache.json + Nominatim）
  5. station_cache.json から最寄駅を推定
  6. (district_code, built_year) で推定建物グルーピング
  7. results/transactions.json に出力

使い方:
  REINFOLIB_API_KEY=xxx python3 build_transaction_feed.py
  REINFOLIB_API_KEY=xxx python3 build_transaction_feed.py --quarters 8  # 過去2年分

環境変数:
  REINFOLIB_API_KEY  — 不動産情報ライブラリ API のサブスクリプションキー（必須）
"""

import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
from datetime import datetime
from typing import Any, Dict, List, Optional, Tuple

import requests

# ---------------------------------------------------------------------------
# reinfolib_cache_builder の共通ユーティリティを再利用
# ---------------------------------------------------------------------------
from reinfolib_cache_builder import (
    api_request,
    get_api_key,
    normalize_text,
    parse_area,
    parse_building_year,
    parse_trade_price,
    PRICE_ENDPOINT,
)

# config.py のフィルタ条件をインポート
from config import (
    PRICE_MIN_MAN,
    PRICE_MAX_MAN,
    AREA_MIN_M2,
    LAYOUT_PREFIX_OK,
    BUILT_YEAR_MIN,
)

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(SCRIPT_DIR, "data")
RESULTS_DIR = os.path.join(SCRIPT_DIR, "results")

CITY_CODES_PATH = os.path.join(DATA_DIR, "shutoken_city_codes.json")
GEOCODE_CACHE_PATH = os.path.join(DATA_DIR, "geocode_cache.json")
STATION_CACHE_PATH = os.path.join(DATA_DIR, "station_cache.json")
OUTPUT_PATH = os.path.join(RESULTS_DIR, "transactions.json")

# API リクエスト間隔（秒）
REQUEST_DELAY_SEC = 2
# ジオコーディング間隔（秒 — Nominatim の利用規約に準拠）
GEOCODE_DELAY_SEC = 1.1

# 都道府県コード → 都道府県名
PREF_NAMES = {"11": "埼玉県", "12": "千葉県", "13": "東京都", "14": "神奈川県"}

# 直線距離 → 徒歩推定の係数（直線 80m ≒ 実道路 100m ≒ 徒歩1分）
WALK_SPEED_M_PER_MIN = 80


# ---------------------------------------------------------------------------
# 1. 市区町村コードのロード
# ---------------------------------------------------------------------------

def load_city_codes() -> List[Dict[str, str]]:
    """
    shutoken_city_codes.json から [{id, name, prefecture, pref_name}] をロード。
    """
    with open(CITY_CODES_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)

    cities: List[Dict[str, str]] = []
    for pref_code, pref_info in data["prefectures"].items():
        pref_name = pref_info["name"]
        for city in pref_info["cities"]:
            cities.append({
                "id": city["id"],
                "name": city["name"],
                "prefecture": pref_code,
                "pref_name": pref_name,
            })
    return cities


# ---------------------------------------------------------------------------
# 2. reinfolib API からデータ取得
# ---------------------------------------------------------------------------

def get_recent_periods(num_quarters: int = 4) -> List[Tuple[int, int]]:
    """直近 N 四半期の (year, quarter) リストを返す。"""
    now = datetime.now()
    current_year = now.year
    current_quarter = (now.month - 1) // 3 + 1

    periods = []
    y, q = current_year, current_quarter
    for _ in range(num_quarters):
        # 1つ前の四半期に戻す（データ集計ラグを考慮し、当四半期はスキップ）
        q -= 1
        if q == 0:
            q = 4
            y -= 1
        periods.append((y, q))
    periods.reverse()
    return periods


def fetch_city_transactions(
    city_code: str,
    year: int,
    quarter: int,
    api_key: str,
) -> List[dict]:
    """指定市区町村・四半期の成約データ（中古マンション等）を取得。"""
    params = {
        "year": year,
        "quarter": quarter,
        "city": city_code,
        "priceClassification": "02",  # 成約価格
    }
    result = api_request(PRICE_ENDPOINT, params, api_key)
    if result is None:
        return []

    data = result.get("data", [])
    return [item for item in data if "中古マンション" in item.get("Type", "")]


# ---------------------------------------------------------------------------
# 3. config.py 条件でフィルタ
# ---------------------------------------------------------------------------

def matches_criteria(item: dict) -> bool:
    """取引レコードが購入条件に合致するか判定。"""
    # 価格チェック
    tp = parse_trade_price(item)
    if tp is None:
        return False
    price_man = tp / 10000
    if price_man < PRICE_MIN_MAN or price_man > PRICE_MAX_MAN:
        return False

    # 面積チェック
    area = parse_area(item)
    if area is None or area < AREA_MIN_M2:
        return False

    # 間取りチェック
    floor_plan_raw = item.get("FloorPlan", "")
    floor_plan = normalize_text(floor_plan_raw) if floor_plan_raw else ""
    if not floor_plan or not any(floor_plan.startswith(p) for p in LAYOUT_PREFIX_OK):
        return False

    # 築年チェック
    built_year = parse_building_year(item.get("BuildingYear"))
    if built_year is None or built_year < BUILT_YEAR_MIN:
        return False

    return True


# ---------------------------------------------------------------------------
# 4. ジオコーディング
# ---------------------------------------------------------------------------

def load_geocode_cache() -> Dict[str, List[float]]:
    """既存の geocode_cache.json をロード。"""
    if os.path.exists(GEOCODE_CACHE_PATH):
        with open(GEOCODE_CACHE_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


def save_geocode_cache(cache: Dict[str, List[float]]) -> None:
    """geocode_cache.json を保存。"""
    with open(GEOCODE_CACHE_PATH, "w", encoding="utf-8") as f:
        json.dump(cache, f, ensure_ascii=False, indent=2)


def geocode_nominatim(address: str) -> Optional[Tuple[float, float]]:
    """Nominatim (OpenStreetMap) でジオコーディング。"""
    try:
        resp = requests.get(
            "https://nominatim.openstreetmap.org/search",
            params={"q": address, "format": "json", "limit": 1, "countrycodes": "jp"},
            headers={"User-Agent": "RealEstateApp/1.0 (personal use)"},
            timeout=10,
        )
        if resp.status_code == 200:
            results = resp.json()
            if results:
                lat = float(results[0]["lat"])
                lon = float(results[0]["lon"])
                return (lat, lon)
    except Exception as e:
        print(f"  Nominatim エラー: {address} — {e}", file=sys.stderr)
    return None


def geocode_districts(
    addresses: List[str],
    cache: Dict[str, List[float]],
) -> Dict[str, Optional[Tuple[float, float]]]:
    """
    アドレスリストをジオコーディング。キャッシュ優先、不足分は Nominatim。
    """
    results: Dict[str, Optional[Tuple[float, float]]] = {}
    uncached = []

    for addr in addresses:
        if addr in cache:
            coord = cache[addr]
            results[addr] = (coord[0], coord[1])
        else:
            uncached.append(addr)

    if uncached:
        print(f"  ジオコーディング: {len(uncached)} 件 (キャッシュ: {len(addresses) - len(uncached)} 件)", file=sys.stderr)
        for i, addr in enumerate(uncached):
            coord = geocode_nominatim(addr)
            if coord:
                cache[addr] = [coord[0], coord[1]]
                results[addr] = coord
            else:
                results[addr] = None
            if i < len(uncached) - 1:
                time.sleep(GEOCODE_DELAY_SEC)

    return results


# ---------------------------------------------------------------------------
# 5. 最寄駅推定
# ---------------------------------------------------------------------------

def load_station_cache() -> Dict[str, Tuple[float, float]]:
    """station_cache.json から {駅名: (lat, lng)} をロード。"""
    if not os.path.exists(STATION_CACHE_PATH):
        return {}
    with open(STATION_CACHE_PATH, "r", encoding="utf-8") as f:
        raw = json.load(f)
    return {name: (coords[0], coords[1]) for name, coords in raw.items()}


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """2地点間の距離をメートルで返す（Haversine 公式）。"""
    R = 6371000
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlam = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlam / 2) ** 2
    return 2 * R * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def find_nearest_station(
    lat: float, lon: float, stations: Dict[str, Tuple[float, float]]
) -> Optional[Tuple[str, int]]:
    """最寄駅名と推定徒歩分を返す。"""
    best_name = None
    best_dist = float("inf")
    for name, (slat, slon) in stations.items():
        d = haversine_m(lat, lon, slat, slon)
        if d < best_dist:
            best_dist = d
            best_name = name
    if best_name is None:
        return None
    walk_min = max(1, round(best_dist / WALK_SPEED_M_PER_MIN))
    return (best_name, walk_min)


# ---------------------------------------------------------------------------
# 6. レコード変換・グルーピング
# ---------------------------------------------------------------------------

def make_transaction_id(item: dict, city_code: str, period: str) -> str:
    """取引レコードのユニーク ID を生成。"""
    raw = f"{city_code}-{item.get('DistrictCode','')}-{item.get('BuildingYear','')}-{period}-{item.get('TradePrice','')}-{item.get('Area','')}-{item.get('FloorPlan','')}"
    return "tx-" + hashlib.md5(raw.encode()).hexdigest()[:12]


def build_transaction_record(
    item: dict,
    city_info: Dict[str, str],
    period_label: str,
    geocode_results: Dict[str, Optional[Tuple[float, float]]],
    stations: Dict[str, Tuple[float, float]],
) -> Optional[dict]:
    """API レスポンス1件 → transactions.json 用レコードに変換。"""
    tp = parse_trade_price(item)
    area = parse_area(item)
    if tp is None or area is None or area <= 0:
        return None

    price_man = round(tp / 10000)
    m2_price = round(tp / area)

    floor_plan_raw = item.get("FloorPlan", "")
    floor_plan = normalize_text(floor_plan_raw) if floor_plan_raw else ""
    structure_raw = item.get("Structure", "")
    structure = normalize_text(structure_raw) if structure_raw else ""

    built_year = parse_building_year(item.get("BuildingYear"))
    district_name = item.get("DistrictName", "")
    district_code = item.get("DistrictCode", "")

    # ジオコーディング
    pref_name = city_info["pref_name"]
    city_name = item.get("Municipality", city_info["name"])
    address = f"{pref_name}{city_name}{district_name}"
    coord = geocode_results.get(address)

    lat = coord[0] if coord else None
    lon = coord[1] if coord else None

    # 最寄駅推定
    nearest_station = None
    estimated_walk_min = None
    if lat and lon and stations:
        result = find_nearest_station(lat, lon, stations)
        if result:
            nearest_station, estimated_walk_min = result

    # 推定建物グループ ID
    building_group_id = f"{district_code}-{built_year}" if district_code and built_year else None

    tx_id = make_transaction_id(item, city_info["id"], period_label)

    return {
        "id": tx_id,
        "prefecture": pref_name,
        "ward": city_name,
        "district": district_name,
        "district_code": district_code,
        "price_man": price_man,
        "area_m2": area,
        "m2_price": m2_price,
        "layout": floor_plan,
        "built_year": built_year,
        "structure": structure,
        "trade_period": period_label,
        "nearest_station": nearest_station,
        "estimated_walk_min": estimated_walk_min,
        "latitude": lat,
        "longitude": lon,
        "building_group_id": building_group_id,
    }


def build_building_groups(transactions: List[dict]) -> List[dict]:
    """取引レコードから推定建物グループのサマリーを構築。"""
    groups: Dict[str, List[dict]] = {}
    for tx in transactions:
        gid = tx.get("building_group_id")
        if gid:
            groups.setdefault(gid, []).append(tx)

    result = []
    for gid, txs in sorted(groups.items()):
        prices = [t["price_man"] for t in txs]
        m2_prices = [t["m2_price"] for t in txs]
        periods = sorted(set(t["trade_period"] for t in txs))
        sample = txs[0]
        result.append({
            "group_id": gid,
            "prefecture": sample["prefecture"],
            "ward": sample["ward"],
            "district": sample["district"],
            "built_year": sample["built_year"],
            "structure": sample.get("structure", ""),
            "nearest_station": sample.get("nearest_station"),
            "estimated_walk_min": sample.get("estimated_walk_min"),
            "latitude": sample.get("latitude"),
            "longitude": sample.get("longitude"),
            "transaction_count": len(txs),
            "price_range_man": [min(prices), max(prices)],
            "avg_m2_price": round(sum(m2_prices) / len(m2_prices)),
            "periods": periods,
            "latest_period": periods[-1] if periods else None,
        })
    return result


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="首都圏成約実績データを取得・フィルタ・ジオコードして transactions.json を生成"
    )
    ap.add_argument(
        "--quarters", type=int, default=4,
        help="取得する四半期数（デフォルト: 4 = 過去1年）",
    )
    ap.add_argument(
        "--output", default=OUTPUT_PATH,
        help=f"出力先 (デフォルト: {OUTPUT_PATH})",
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="API 呼び出しをスキップし、既存の中間データで処理",
    )
    args = ap.parse_args()

    os.makedirs(os.path.dirname(args.output), exist_ok=True)

    api_key = get_api_key()
    cities = load_city_codes()
    periods = get_recent_periods(args.quarters)
    period_labels = [f"{y}Q{q}" for y, q in periods]

    print("=== 首都圏成約実績フィード構築開始 ===", file=sys.stderr)
    print(f"  対象市区町村: {len(cities)} 件", file=sys.stderr)
    print(f"  対象期間: {period_labels}", file=sys.stderr)
    print(f"  フィルタ: {PRICE_MIN_MAN}〜{PRICE_MAX_MAN}万, {AREA_MIN_M2}㎡+, "
          f"間取り{LAYOUT_PREFIX_OK}, 築{BUILT_YEAR_MIN}年以降", file=sys.stderr)

    # --- Phase 1: API からデータ取得 + フィルタ ---
    all_matched: List[Tuple[dict, Dict[str, str], str]] = []  # (item, city_info, period)
    total_fetched = 0
    total_matched = 0

    for ci, city in enumerate(cities):
        city_matched = 0
        for year, quarter in periods:
            qlabel = f"{year}Q{quarter}"
            items = fetch_city_transactions(city["id"], year, quarter, api_key)
            total_fetched += len(items)

            for item in items:
                if matches_criteria(item):
                    all_matched.append((item, city, qlabel))
                    city_matched += 1
                    total_matched += 1

            time.sleep(REQUEST_DELAY_SEC)

        if city_matched > 0:
            print(f"  [{ci+1}/{len(cities)}] {city['pref_name']}{city['name']}: "
                  f"{city_matched} 件マッチ", file=sys.stderr)
        elif (ci + 1) % 50 == 0:
            print(f"  [{ci+1}/{len(cities)}] 進捗...", file=sys.stderr)

    print(f"\n  取得合計: {total_fetched} 件 → フィルタ後: {total_matched} 件", file=sys.stderr)

    # --- Phase 2: ジオコーディング ---
    print("\n--- ジオコーディング ---", file=sys.stderr)
    geocode_cache = load_geocode_cache()

    # ユニークなアドレスを収集
    unique_addresses = set()
    for item, city_info, _ in all_matched:
        pref_name = city_info["pref_name"]
        city_name = item.get("Municipality", city_info["name"])
        district_name = item.get("DistrictName", "")
        address = f"{pref_name}{city_name}{district_name}"
        unique_addresses.add(address)

    geocode_results = geocode_districts(sorted(unique_addresses), geocode_cache)
    save_geocode_cache(geocode_cache)

    geocoded_count = sum(1 for v in geocode_results.values() if v is not None)
    print(f"  ジオコーディング完了: {geocoded_count}/{len(unique_addresses)} 成功", file=sys.stderr)

    # --- Phase 3: 最寄駅推定 ---
    print("\n--- 最寄駅推定 ---", file=sys.stderr)
    stations = load_station_cache()
    print(f"  駅データ: {len(stations)} 駅", file=sys.stderr)

    # --- Phase 4: レコード変換 ---
    print("\n--- レコード変換・グルーピング ---", file=sys.stderr)
    transactions: List[dict] = []
    for item, city_info, period in all_matched:
        rec = build_transaction_record(
            item, city_info, period, geocode_results, stations
        )
        if rec:
            transactions.append(rec)

    # 重複除去（同一 ID）
    seen_ids = set()
    unique_transactions = []
    for tx in transactions:
        if tx["id"] not in seen_ids:
            seen_ids.add(tx["id"])
            unique_transactions.append(tx)
    transactions = unique_transactions

    # 建物グループ構築
    building_groups = build_building_groups(transactions)

    print(f"  取引レコード: {len(transactions)} 件", file=sys.stderr)
    print(f"  推定建物グループ: {len(building_groups)} 件", file=sys.stderr)

    # --- Phase 5: 出力 ---
    output = {
        "transactions": transactions,
        "building_groups": building_groups,
        "metadata": {
            "updated_at": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            "periods_covered": period_labels,
            "data_source": "不動産情報ライブラリ（国土交通省）成約価格情報",
            "filter_criteria": {
                "price_range_man": [PRICE_MIN_MAN, PRICE_MAX_MAN],
                "area_min_m2": AREA_MIN_M2,
                "layout_prefix": list(LAYOUT_PREFIX_OK),
                "built_year_min": BUILT_YEAR_MIN,
            },
            "transaction_count": len(transactions),
            "building_group_count": len(building_groups),
            "scope": "首都圏（東京都・神奈川県・埼玉県・千葉県）",
        },
    }

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(output, f, ensure_ascii=False, indent=2)

    print(f"\n=== 完了: {args.output} ({len(transactions)} 件) ===", file=sys.stderr)

    # サマリー
    by_pref: Dict[str, int] = {}
    for tx in transactions:
        by_pref[tx["prefecture"]] = by_pref.get(tx["prefecture"], 0) + 1
    for pref, count in sorted(by_pref.items()):
        print(f"  {pref}: {count} 件", file=sys.stderr)


if __name__ == "__main__":
    main()
