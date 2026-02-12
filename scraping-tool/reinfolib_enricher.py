#!/usr/bin/env python3
"""
物件 JSON に不動産情報ライブラリの相場データを付与する enricher。

reinfolib_cache_builder.py で事前に構築した
  data/reinfolib_prices.json          — 区別m²単価中央値
  data/reinfolib_trends.json          — 区別四半期推移
  data/reinfolib_raw_transactions.json — 直近4四半期の個別取引レコード
を参照し、各物件に以下のフィールドを追加する:

  reinfolib_market_data (JSON文字列):
    {
      "ward": "港区",
      --- 段階的マッチング比較 ---
      "ward_median_m2_price": 1285000,    # マッチした成約価格m²単価中央値
      "ward_mean_m2_price": 1310000,      # マッチした成約価格m²単価平均
      "price_ratio": 1.08,               # 掲載価格 ÷ 相場 (1.0=相場並み)
      "price_diff_man": 620,             # 相場との差額（万円, 正=割高）
      "sample_count": 24,                # マッチしたサンプル数
      "match_tier": 1,                   # マッチTier (1=精密, 2=標準, 3=広め, 4=区全体)
      "match_description": "港区・3LDK・50-80m²・築±10年",  # マッチ条件説明
      --- トレンド ---
      "trend": "up",                     # 直近トレンド (up/flat/down)
      "yoy_change_pct": 3.2,             # 直近の前年同期比変動率 (%)
      "quarterly_m2_prices": [            # 四半期推移 (チャート用)
        {"quarter": "2021Q1", "median_m2_price": 980000, "count": 30},
        ...
      ],
      --- 同一マンション候補の成約事例 ---
      "same_building_transactions": [
        {
          "period": "2025Q2",
          "floor_plan": "3LDK",
          "area": 72.0,
          "trade_price_man": 9500,
          "m2_price": 1319444
        },
        ...
      ],
      "data_source": "不動産情報ライブラリ（国土交通省）"
    }

使い方:
  python3 reinfolib_enricher.py --input results/latest.json --output results/latest.json
  python3 reinfolib_enricher.py --input results/latest.json --output results/latest.json --force

※ API は叩かない。ローカルキャッシュのみ参照。
"""

import argparse
import json
import os
import re
import statistics
import sys
from typing import Any, Dict, List, Optional, Tuple

# ---------------------------------------------------------------------------
# キャッシュ読み込み
# ---------------------------------------------------------------------------

DATA_DIR = os.path.join(os.path.dirname(__file__), "data")
PRICES_CACHE = os.path.join(DATA_DIR, "reinfolib_prices.json")
TRENDS_CACHE = os.path.join(DATA_DIR, "reinfolib_trends.json")
RAW_TX_CACHE = os.path.join(DATA_DIR, "reinfolib_raw_transactions.json")


def load_json_file(path: str) -> Optional[dict]:
    """JSON ファイルを読み込む。なければ None。"""
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# 住所から区名・町名を抽出
# ---------------------------------------------------------------------------

def extract_ward(address: Optional[str]) -> Optional[str]:
    """住所文字列から区名を抽出 (例: '東京都江東区豊洲5丁目' → '江東区')。"""
    if not address:
        return None
    m = re.search(r"(?<=[都道府県])\S+?区", address)
    if m:
        return m.group(0)
    return None


def extract_district(address: Optional[str]) -> Optional[str]:
    """
    住所文字列から町名を抽出 (例: '東京都港区麻布台1丁目3-1' → '麻布台')。
    reinfolib API の DistrictName と照合するため。
    """
    if not address:
        return None
    # 「区」の直後から、最初の数字・丁目・番地の手前まで
    m = re.search(r"区([^\d０-９丁番]+)", address)
    if m:
        return m.group(1).strip()
    # 数字がない場合（例: "港区赤坂"）
    m = re.search(r"区(\S+)$", address)
    if m:
        return m.group(1).strip()
    return None


# ---------------------------------------------------------------------------
# 間取り正規化
# ---------------------------------------------------------------------------

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


def layout_group(layout: Optional[str]) -> Optional[str]:
    """
    間取りをグループ化して比較しやすくする。
    例: '3LDK+S' → '3LDK', '2SLDK' → '2LDK', '２ＬＤＫ' → '2LDK'
    """
    if not layout:
        return None
    normalized = normalize_text(layout).upper()
    # "3LDK+S", "3SLDK", "3LDK" → "3LDK"
    m = re.match(r"(\d+)\s*S?\s*(LDK|DK|LK|K)", normalized)
    if m:
        return f"{m.group(1)}{m.group(2)}"
    # "1R" → "1R" (ワンルーム)
    m = re.match(r"(\d+)\s*R", normalized)
    if m:
        return f"{m.group(1)}R"
    return normalized


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
# 段階的マッチング
# ---------------------------------------------------------------------------

# マッチング Tier 定義
# Tier 1: 同区 + 同間取りグループ + 面積±15m² + 築年±10年
# Tier 2: 同区 + 同間取りグループ + 面積±20m²
# Tier 3: 同区 + 同間取りグループ
# Tier 4: 同区のみ（フォールバック）
MIN_SAMPLES = 10


def _filter_transactions(
    transactions: List[dict],
    ward: str,
    layout_grp: Optional[str],
    area_m2: Optional[float],
    built_year: Optional[int],
    tier: int,
) -> List[dict]:
    """指定 Tier の条件でフィルタリング。"""
    result = []
    for tx in transactions:
        # 全 Tier 共通: 同区
        if tx["ward"] != ward:
            continue

        if tier <= 3 and layout_grp:
            # Tier 1-3: 同間取りグループ
            tx_layout_grp = layout_group(tx.get("floor_plan"))
            if tx_layout_grp != layout_grp:
                continue

        if tier <= 2 and area_m2 is not None:
            # Tier 1-2: 面積近似
            tx_area = tx.get("area")
            if tx_area is None:
                continue
            tolerance = 15.0 if tier == 1 else 20.0
            if abs(tx_area - area_m2) > tolerance:
                continue

        if tier == 1 and built_year is not None:
            # Tier 1: 築年近似 (±10年)
            tx_by = tx.get("building_year")
            if tx_by is None:
                continue
            if abs(tx_by - built_year) > 10:
                continue

        result.append(tx)
    return result


def find_best_tier_match(
    transactions: List[dict],
    ward: str,
    layout_grp: Optional[str],
    area_m2: Optional[float],
    built_year: Optional[int],
) -> Tuple[List[dict], int, str]:
    """
    段階的にマッチングし、十分なサンプル数が取れた最初の Tier を返す。

    Returns:
        (matched_transactions, tier, description)
    """
    for tier in range(1, 5):
        matched = _filter_transactions(
            transactions, ward, layout_grp, area_m2, built_year, tier
        )
        if len(matched) >= MIN_SAMPLES or tier == 4:
            desc = _build_match_description(
                ward, layout_grp, area_m2, built_year, tier
            )
            return matched, tier, desc

    # ここには到達しないが念のため
    return [], 4, ward


def _build_match_description(
    ward: str,
    layout_grp: Optional[str],
    area_m2: Optional[float],
    built_year: Optional[int],
    tier: int,
) -> str:
    """Tier に応じたマッチ条件の人間可読な説明文を生成。"""
    parts = [ward]

    if tier <= 3 and layout_grp:
        parts.append(layout_grp)

    if tier <= 2 and area_m2 is not None:
        tol = 15.0 if tier == 1 else 20.0
        lo = max(0, int(area_m2 - tol))
        hi = int(area_m2 + tol)
        parts.append(f"{lo}-{hi}m²")

    if tier == 1 and built_year is not None:
        parts.append(f"築{built_year - 10}-{built_year + 10}年")

    return "・".join(parts)


# ---------------------------------------------------------------------------
# 同一マンション候補の成約事例
# ---------------------------------------------------------------------------

def find_same_building_transactions(
    transactions: List[dict],
    ward: str,
    district_name: Optional[str],
    built_year: Optional[int],
    structure: Optional[str],
) -> List[dict]:
    """
    同一マンション候補の成約事例を抽出。
    条件: 同区 + 同町名 + 築年±1年 + 同構造（構造不明時はスキップ）
    """
    if not district_name or not built_year:
        return []

    results = []
    for tx in transactions:
        if tx["ward"] != ward:
            continue
        if tx.get("district_name") != district_name:
            continue
        tx_by = tx.get("building_year")
        if tx_by is None or abs(tx_by - built_year) > 1:
            continue
        # 構造が判明している場合のみ照合（片方不明なら通す）
        if structure and tx.get("structure"):
            if normalize_text(structure).upper() != normalize_text(tx["structure"]).upper():
                continue
        results.append(tx)

    # 新しい取引を先に表示
    results.sort(key=lambda x: x.get("period", ""), reverse=True)
    return results


def format_same_building_tx(tx: dict) -> dict:
    """同一マンション事例を iOS 表示用に整形。"""
    trade_price = tx.get("trade_price", 0)
    return {
        "period": tx.get("period", ""),
        "floor_plan": tx.get("floor_plan", ""),
        "area": tx.get("area", 0),
        "trade_price_man": round(trade_price / 10000) if trade_price else 0,
        "m2_price": tx.get("m2_price", 0),
    }


# ---------------------------------------------------------------------------
# Enricher 本体
# ---------------------------------------------------------------------------

def enrich_reinfolib(listings: list, force: bool = False) -> int:
    """
    物件リストに reinfolib_market_data を追加する。
    force=True の場合、既存データがあっても上書きする。
    """
    prices = load_json_file(PRICES_CACHE)
    trends = load_json_file(TRENDS_CACHE)
    raw_tx_data = load_json_file(RAW_TX_CACHE)

    if not prices:
        print("警告: reinfolib_prices.json が見つかりません。スキップします。", file=sys.stderr)
        print(f"  期待パス: {PRICES_CACHE}", file=sys.stderr)
        return 0

    prices_by_ward = prices.get("by_ward", {})
    trends_by_ward = trends.get("by_ward", {}) if trends else {}
    data_source = prices.get("data_source", "不動産情報ライブラリ（国土交通省）")

    # 個別取引レコード（段階的マッチング用）
    all_transactions: List[dict] = []
    if raw_tx_data:
        all_transactions = raw_tx_data.get("transactions", [])
        print(
            f"個別取引レコード: {len(all_transactions)} 件読み込み",
            file=sys.stderr,
        )
    else:
        print(
            "警告: reinfolib_raw_transactions.json が見つかりません。"
            "区全体の比較にフォールバックします。",
            file=sys.stderr,
        )

    # ward 別にインデックス化（高速化）
    tx_by_ward: Dict[str, List[dict]] = {}
    for tx in all_transactions:
        w = tx.get("ward", "")
        if w not in tx_by_ward:
            tx_by_ward[w] = []
        tx_by_ward[w].append(tx)

    enriched_count = 0

    for listing in listings:
        # 既にデータがある場合はスキップ（force でない限り）
        if not force and listing.get("reinfolib_market_data"):
            continue

        # 住所から区名を抽出（ss_address 優先）
        address = listing.get("ss_address") or listing.get("address")
        ward = extract_ward(address)
        if not ward:
            continue

        ward_prices = prices_by_ward.get(ward)
        if not ward_prices:
            continue

        # 物件情報を取得
        price_man = listing.get("price_man")
        area_m2 = listing.get("area_m2")
        layout = listing.get("layout")
        built_year = listing.get("built_year")
        district_name = extract_district(address)
        # 構造情報（floor_structure から取得: "RC43階建" → "RC"）
        floor_structure = listing.get("floor_structure") or ""
        structure_match = re.match(r"(SRC|RC|S|W)", floor_structure.upper())
        structure = structure_match.group(1) if structure_match else None

        # =====================================================================
        # 段階的マッチング比較
        # =====================================================================
        ward_txs = tx_by_ward.get(ward, [])
        listing_layout_grp = layout_group(layout)

        if ward_txs:
            matched_txs, match_tier, match_desc = find_best_tier_match(
                ward_txs, ward, listing_layout_grp, area_m2, built_year
            )

            # マッチした取引から m² 単価を集計
            matched_m2_prices = [
                tx["m2_price"] for tx in matched_txs
                if tx.get("m2_price") is not None and tx["m2_price"] > 0
            ]

            if matched_m2_prices:
                median_m2 = round(statistics.median(matched_m2_prices))
                mean_m2 = round(statistics.mean(matched_m2_prices))
                sample_count = len(matched_m2_prices)
            else:
                # フォールバック: 区全体の集計値
                median_m2 = ward_prices.get("median_m2_price")
                mean_m2 = ward_prices.get("mean_m2_price")
                sample_count = ward_prices.get("sample_count", 0)
                match_tier = 4
                match_desc = ward
        else:
            # raw_transactions がない場合: 区全体の集計値にフォールバック
            median_m2 = ward_prices.get("median_m2_price")
            mean_m2 = ward_prices.get("mean_m2_price")
            sample_count = ward_prices.get("sample_count", 0)
            match_tier = 4
            match_desc = ward

        if not median_m2:
            continue

        # 物件の m² 単価を算出し、相場と比較
        price_ratio = None
        price_diff_man = None

        if price_man and area_m2 and area_m2 > 0:
            listing_m2_price = (price_man * 10000) / area_m2  # 万円→円
            price_ratio = round(listing_m2_price / median_m2, 3)
            # 差額（万円）= (物件m²単価 - 相場m²単価) × 面積 ÷ 10000
            price_diff_man = round(
                (listing_m2_price - median_m2) * area_m2 / 10000
            )

        # =====================================================================
        # トレンド情報（区全体の四半期推移を使用）
        # =====================================================================
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

        # =====================================================================
        # 同一マンション候補の成約事例
        # =====================================================================
        same_building_txs = []
        if ward_txs:
            raw_sb_txs = find_same_building_transactions(
                ward_txs, ward, district_name, built_year, structure
            )
            same_building_txs = [
                format_same_building_tx(tx) for tx in raw_sb_txs
            ]

        # =====================================================================
        # market_data を構築
        # =====================================================================
        market_data: Dict[str, Any] = {
            "ward": ward,
            # 段階的マッチング比較
            "ward_median_m2_price": median_m2,
            "ward_mean_m2_price": mean_m2,
            "price_ratio": price_ratio,
            "price_diff_man": price_diff_man,
            "sample_count": sample_count,
            "match_tier": match_tier,
            "match_description": match_desc,
            # トレンド
            "trend": trend,
            "yoy_change_pct": yoy,
            "quarterly_m2_prices": quarterly_prices,
            # 同一マンション事例
            "same_building_transactions": same_building_txs,
            # メタデータ
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
    ap.add_argument(
        "--force",
        action="store_true",
        help="既存データがある場合も上書きする",
    )
    args = ap.parse_args()

    with open(args.input, "r", encoding="utf-8") as f:
        listings = json.load(f)

    count = enrich_reinfolib(listings, force=args.force)

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False, indent=2)

    print(
        f"不動産情報ライブラリ enrichment 完了: {count}/{len(listings)} 件に相場データを付与",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
