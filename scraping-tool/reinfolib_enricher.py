#!/usr/bin/env python3
"""
物件 JSON に不動産情報ライブラリの相場データを付与する enricher。

reinfolib_cache_builder.py で事前に構築した
  data/reinfolib_prices.json  — 区別m²単価中央値
  data/reinfolib_trends.json  — 区別四半期推移
を参照し、各物件に以下のフィールドを追加する:

  reinfolib_market_data (JSON文字列):
    {
      "ward_median_m2_price": 1285000,    # 同区の成約価格m²単価中央値
      "ward_mean_m2_price": 1310000,      # 同区の成約価格m²単価平均
      "price_ratio": 1.08,               # 掲載価格 ÷ 相場 (1.0=相場並み)
      "price_diff_man": 620,             # 相場との差額（万円, 正=割高）
      "sample_count": 42,                # 算出に使ったサンプル数
      "trend": "up",                     # 直近トレンド (up/flat/down)
      "yoy_change_pct": 3.2,             # 直近の前年同期比変動率 (%)
      "quarterly_m2_prices": [            # 四半期推移 (チャート用)
        {"quarter": "2021Q1", "median_m2_price": 980000, "count": 30},
        ...
      ],
      "data_source": "不動産情報ライブラリ（国土交通省）"
    }

使い方:
  python3 reinfolib_enricher.py --input results/latest.json --output results/latest.json

※ API は叩かない。ローカルキャッシュのみ参照。
"""

import argparse
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional

# ---------------------------------------------------------------------------
# キャッシュ読み込み
# ---------------------------------------------------------------------------

DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
PRICES_CACHE = os.path.join(DATA_DIR, "reinfolib_prices.json")
TRENDS_CACHE = os.path.join(DATA_DIR, "reinfolib_trends.json")


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
# トレンド判定
# ---------------------------------------------------------------------------

def determine_trend(quarters: List[dict]) -> str:
    """
    直近4四半期の中央値推移からトレンドを判定。
    - 3四半期以上上昇 → "up"
    - 3四半期以上下降 → "down"
    - その他 → "flat"
    """
    # 有効データのある四半期を直近から取得
    valid = [q for q in quarters if q.get("median_m2_price") is not None]
    if len(valid) < 3:
        return "flat"

    recent = valid[-4:] if len(valid) >= 4 else valid
    ups = 0
    downs = 0
    for i in range(1, len(recent)):
        prev = recent[i - 1]["median_m2_price"]
        curr = recent[i]["median_m2_price"]
        if prev and curr:
            if curr > prev:
                ups += 1
            elif curr < prev:
                downs += 1

    total = ups + downs
    if total == 0:
        return "flat"
    if ups / max(total, 1) >= 0.67:
        return "up"
    if downs / max(total, 1) >= 0.67:
        return "down"
    return "flat"


def get_latest_yoy(quarters: List[dict]) -> Optional[float]:
    """直近の前年同期比変動率を返す。"""
    for q in reversed(quarters):
        if q.get("yoy_change_pct") is not None:
            return q["yoy_change_pct"]
    return None


# ---------------------------------------------------------------------------
# Enricher 本体
# ---------------------------------------------------------------------------

def enrich_reinfolib(listings: list) -> int:
    """
    物件リストに reinfolib_market_data を追加する。
    既にある場合はスキップ。
    """
    prices = load_json_file(PRICES_CACHE)
    trends = load_json_file(TRENDS_CACHE)

    if not prices:
        print("警告: reinfolib_prices.json が見つかりません。スキップします。", file=sys.stderr)
        print(f"  期待パス: {PRICES_CACHE}", file=sys.stderr)
        return 0

    prices_by_ward = prices.get("by_ward", {})
    trends_by_ward = trends.get("by_ward", {}) if trends else {}
    data_source = prices.get("data_source", "不動産情報ライブラリ（国土交通省）")

    enriched_count = 0

    for listing in listings:
        # 既にデータがある場合はスキップ
        if listing.get("reinfolib_market_data"):
            continue

        # 住所から区名を抽出
        ward = extract_ward(listing.get("address"))
        if not ward:
            continue

        ward_prices = prices_by_ward.get(ward)
        if not ward_prices:
            continue

        ward_median_m2 = ward_prices.get("median_m2_price")
        ward_mean_m2 = ward_prices.get("mean_m2_price")
        sample_count = ward_prices.get("sample_count", 0)

        if not ward_median_m2:
            continue

        # 物件の m² 単価を算出
        price_man = listing.get("price_man")
        area_m2 = listing.get("area_m2")

        price_ratio = None
        price_diff_man = None

        if price_man and area_m2 and area_m2 > 0:
            listing_m2_price = (price_man * 10000) / area_m2  # 万円→円
            price_ratio = round(listing_m2_price / ward_median_m2, 3)
            # 差額（万円）= (物件m²単価 - 相場m²単価) × 面積 ÷ 10000
            price_diff_man = round((listing_m2_price - ward_median_m2) * area_m2 / 10000)

        # トレンド情報
        ward_trend_data = trends_by_ward.get(ward, {})
        quarters = ward_trend_data.get("quarters", [])
        trend = determine_trend(quarters)
        yoy = get_latest_yoy(quarters)

        # 四半期推移データ（iOS チャート用）
        quarterly_prices = []
        for q in quarters:
            if q.get("median_m2_price") is not None:
                quarterly_prices.append({
                    "quarter": q["quarter"],
                    "median_m2_price": q["median_m2_price"],
                    "count": q.get("count", 0),
                })

        market_data = {
            "ward": ward,
            "ward_median_m2_price": ward_median_m2,
            "ward_mean_m2_price": ward_mean_m2,
            "price_ratio": price_ratio,
            "price_diff_man": price_diff_man,
            "sample_count": sample_count,
            "trend": trend,
            "yoy_change_pct": yoy,
            "quarterly_m2_prices": quarterly_prices,
            "data_source": data_source,
        }

        listing["reinfolib_market_data"] = json.dumps(
            market_data, ensure_ascii=False
        )
        enriched_count += 1

    return enriched_count


# ---------------------------------------------------------------------------
# メイン
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="物件JSONに不動産情報ライブラリの相場データを付与"
    )
    ap.add_argument("--input", required=True, help="入力JSONファイル")
    ap.add_argument("--output", required=True, help="出力JSONファイル")
    args = ap.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        listings = json.load(f)

    count = enrich_reinfolib(listings)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    print(
        f"不動産情報ライブラリ enrichment 完了: {count}/{len(listings)} 件に相場データを付与",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
