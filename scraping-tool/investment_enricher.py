#!/usr/bin/env python3
"""
投資判断支援用の enricher。
各物件に以下のフィールドを付与する:
- price_fairness_score: 掲載価格の妥当性スコア（0-100、50=適正、50未満=割高、50超=割安）
- resale_liquidity_score: 再販流動性スコア（0-100、高い=売りやすい）
- listing_score: 総合投資スコア（0-100）

Phase 7 追加: テスト可能なラッパー関数
- calculate_investment_score, calculate_days_on_market, count_competing_listings
- inject_price_history, enrich_investment_metadata
"""

import json
import math
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

try:
    from report_utils import identity_key, get_ward_from_address, normalize_listing_name
except ImportError:
    sys.path.insert(0, str(Path(__file__).parent))
    from report_utils import identity_key, get_ward_from_address, normalize_listing_name


def _calc_price_fairness(listing: dict) -> Optional[int]:
    """掲載価格の妥当性スコアを算出。成約相場・住まいサーフィン評価との比較。"""
    scores = []

    ss_judgment = (listing.get("ss_value_judgment") or "").strip()
    if ss_judgment:
        judgment_map = {"割安": 80, "やや割安": 65, "適正": 50, "適正価格": 50, "やや割高": 35, "割高": 20}
        if ss_judgment in judgment_map:
            scores.append(judgment_map[ss_judgment])

    ss_m2_discount = listing.get("ss_m2_discount")
    if ss_m2_discount is not None:
        discount_score = 50 + min(max(ss_m2_discount * -2, -40), 40)
        scores.append(int(discount_score))

    market_data = listing.get("reinfolib_market_data")
    if market_data and isinstance(market_data, str):
        try:
            md = json.loads(market_data)
            deviation_pct = md.get("deviation_pct")
            if deviation_pct is not None:
                market_score = 50 - min(max(deviation_pct * 2, -40), 40)
                scores.append(int(market_score))
        except (json.JSONDecodeError, TypeError):
            pass

    if not scores:
        return None
    return min(100, max(0, int(sum(scores) / len(scores))))


def _calc_resale_liquidity(listing: dict, transaction_data: Optional[dict] = None) -> Optional[int]:
    """再販流動性スコアを算出。マンション規模・駅近・エリアの取引量で評価。"""
    scores = []
    weights = []

    total_units = listing.get("total_units")
    if total_units is not None:
        if total_units >= 200:
            scores.append(90)
        elif total_units >= 100:
            scores.append(75)
        elif total_units >= 50:
            scores.append(60)
        else:
            scores.append(40)
        weights.append(2)

    walk_min = listing.get("walk_min")
    if walk_min is not None:
        if walk_min <= 3:
            scores.append(95)
        elif walk_min <= 5:
            scores.append(80)
        elif walk_min <= 7:
            scores.append(65)
        else:
            scores.append(45)
        weights.append(3)

    ward = get_ward_from_address(listing.get("address") or "")
    high_demand_wards = {"港区", "渋谷区", "目黒区", "千代田区", "中央区", "新宿区", "品川区", "文京区"}
    mid_demand_wards = {"世田谷区", "豊島区", "台東区", "江東区", "中野区", "杉並区"}
    if ward in high_demand_wards:
        scores.append(85)
        weights.append(2)
    elif ward in mid_demand_wards:
        scores.append(65)
        weights.append(2)
    elif ward:
        scores.append(45)
        weights.append(2)

    area_m2 = listing.get("area_m2")
    if area_m2 is not None:
        if 55 <= area_m2 <= 80:
            scores.append(80)
        elif 45 <= area_m2 <= 90:
            scores.append(65)
        else:
            scores.append(45)
        weights.append(1)

    if transaction_data:
        ward_key = ward.replace("区", "") if ward else ""
        tx_count = transaction_data.get(ward_key, {}).get("transaction_count", 0)
        if tx_count >= 50:
            scores.append(85)
        elif tx_count >= 20:
            scores.append(65)
        elif tx_count >= 5:
            scores.append(50)
        else:
            scores.append(35)
        weights.append(2)

    if not scores:
        return None
    weighted_sum = sum(s * w for s, w in zip(scores, weights))
    total_weight = sum(weights)
    return min(100, max(0, int(weighted_sum / total_weight)))


def _calc_listing_score(listing: dict) -> Optional[int]:
    """総合投資スコアを算出。各指標の重み付け平均。"""
    scores = []
    weights = []

    fairness = listing.get("price_fairness_score")
    if fairness is not None:
        scores.append(fairness)
        weights.append(3)

    liquidity = listing.get("resale_liquidity_score")
    if liquidity is not None:
        scores.append(liquidity)
        weights.append(2)

    ss_appreciation = listing.get("ss_appreciation_rate")
    if ss_appreciation is not None:
        appreciation_score = 50 + min(max(ss_appreciation * 2, -40), 40)
        scores.append(int(appreciation_score))
        weights.append(3)

    ss_profit = listing.get("ss_profit_pct")
    if ss_profit is not None:
        scores.append(min(100, ss_profit))
        weights.append(2)

    hazard = listing.get("hazard_info")
    if hazard and isinstance(hazard, str):
        try:
            hi = json.loads(hazard)
            risk_count = sum(1 for v in hi.values() if v and str(v) not in ("リスクなし", "対象外", "—", "-", ""))
            hazard_score = max(0, 100 - risk_count * 20)
            scores.append(hazard_score)
            weights.append(1)
        except (json.JSONDecodeError, TypeError):
            pass

    commute_info = listing.get("commute_info")
    if commute_info and isinstance(commute_info, str):
        try:
            ci = json.loads(commute_info)
            commute_times = []
            for dest in ("playground", "m3career"):
                dest_info = ci.get(dest, {})
                if isinstance(dest_info, dict) and dest_info.get("minutes"):
                    commute_times.append(dest_info["minutes"])
            if commute_times:
                avg_commute = sum(commute_times) / len(commute_times)
                if avg_commute <= 20:
                    commute_score = 90
                elif avg_commute <= 30:
                    commute_score = 75
                elif avg_commute <= 45:
                    commute_score = 55
                else:
                    commute_score = 35
                scores.append(commute_score)
                weights.append(2)
        except (json.JSONDecodeError, TypeError):
            pass

    population_data = listing.get("estat_population_data")
    if population_data and isinstance(population_data, str):
        try:
            pd = json.loads(population_data)
            yoy = pd.get("yoy_pct")
            if yoy is not None:
                if yoy > 1:
                    pop_score = 80
                elif yoy > 0:
                    pop_score = 65
                elif yoy > -1:
                    pop_score = 45
                else:
                    pop_score = 30
                scores.append(pop_score)
                weights.append(1)
        except (json.JSONDecodeError, TypeError):
            pass

    if not scores:
        return None
    weighted_sum = sum(s * w for s, w in zip(scores, weights))
    total_weight = sum(weights)
    return min(100, max(0, int(weighted_sum / total_weight)))


def enrich_investment_scores(
    listings: list[dict],
    transaction_data: Optional[dict] = None,
) -> list[dict]:
    """物件リストに投資スコアを付与する。"""
    for listing in listings:
        listing["price_fairness_score"] = _calc_price_fairness(listing)
        listing["resale_liquidity_score"] = _calc_resale_liquidity(listing, transaction_data)
        listing["listing_score"] = _calc_listing_score(listing)

    return listings


def main():
    import argparse
    parser = argparse.ArgumentParser(description="投資スコアリング enricher")
    parser.add_argument("input", help="入力 JSON ファイル")
    parser.add_argument("-o", "--output", help="出力 JSON ファイル（デフォルト: 入力を上書き）")
    parser.add_argument("--transactions", help="成約実績 JSON ファイル（オプション）")
    args = parser.parse_args()

    input_path = Path(args.input)
    output_path = Path(args.output) if args.output else input_path

    with open(input_path, "r", encoding="utf-8") as f:
        listings = json.load(f)

    tx_data = None
    if args.transactions:
        tx_path = Path(args.transactions)
        if tx_path.exists():
            with open(tx_path, "r", encoding="utf-8") as f:
                tx_json = json.load(f)
            tx_data = {}
            for bg in tx_json.get("building_groups", []):
                ward = bg.get("ward", "").replace("区", "")
                if ward not in tx_data:
                    tx_data[ward] = {"transaction_count": 0}
                tx_data[ward]["transaction_count"] += bg.get("transaction_count", 0)

    enrich_investment_scores(listings, tx_data)

    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(listings, f, ensure_ascii=False)

    scored = sum(1 for r in listings if r.get("listing_score") is not None)
    print(f"投資スコア付与完了: {scored}/{len(listings)}件", file=sys.stderr)


# --- Phase 7: テスト可能なラッパー関数 ---

def _building_group_key(listing: dict) -> str:
    """同一マンション判定用キー。物件名（正規化）+ 区名。"""
    name = normalize_listing_name(listing.get("name") or "")
    ward = get_ward_from_address(listing.get("address") or "")
    return f"{name}|{ward or ''}"


def calculate_investment_score(listing: dict[str, Any]) -> float:
    """
    投資スコア（0-100）を算出する。
    asset_score の含み益率ベーススコアを使用。データ不足時は 0。
    """
    try:
        from asset_score import get_asset_score_and_rank
        score, _ = get_asset_score_and_rank(listing)
        return float(score)
    except Exception:
        return 0.0


def calculate_days_on_market(
    listing: dict,
    reference_date: Optional[datetime] = None,
) -> Optional[int]:
    """
    掲載日数を算出する（日数）。
    added_at（ISO 8601）または first_seen があれば reference_date との差分を返す。
    データなしの場合は None。
    """
    ref = reference_date or datetime.utcnow()
    added = listing.get("added_at") or listing.get("first_seen")
    if not added:
        return None
    if isinstance(added, str):
        try:
            from datetime import datetime as dt
            if "T" in added:
                added_dt = dt.fromisoformat(added.replace("Z", "+00:00"))
            else:
                added_dt = dt.strptime(added[:10], "%Y-%m-%d")
            ref_naive = ref.replace(tzinfo=None) if ref.tzinfo else ref
            added_naive = added_dt.replace(tzinfo=None) if added_dt.tzinfo else added_dt
            delta = ref_naive - added_naive
            return max(0, delta.days)
        except (ValueError, TypeError):
            return None
    if hasattr(added, "days"):
        return max(0, added.days)
    return None


def count_competing_listings(listing: dict, all_listings: list[dict]) -> int:
    """
    同一マンション内の競合物件数をカウントする（自物件を含む）。
    building_group_key が一致する物件数を返す。
    """
    key = _building_group_key(listing)
    if not key.strip("|"):
        return 0
    count = 0
    for other in all_listings:
        if _building_group_key(other) == key:
            count += 1
    return count


def inject_price_history(listing: dict, history: list[dict]) -> dict:
    """
    価格履歴を listing に付与する。
    history は [{"date": "YYYY-MM-DD", "price_man": int}, ...] 形式。
    付与後は listing["price_history"] に格納される。
    """
    if not history:
        return listing
    listing = dict(listing)
    listing["price_history"] = [
        {"date": h.get("date"), "price_man": h.get("price_man")}
        for h in history
        if h.get("date") and h.get("price_man") is not None
    ]
    return listing


def enrich_investment_metadata(
    listing: dict,
    all_listings: Optional[list[dict]] = None,
    reference_date: Optional[datetime] = None,
) -> dict:
    """
    1物件に投資メタデータを付与する。
    - investment_score: 0-100
    - days_on_market: 掲載日数（日）
    - competing_listings: 競合物件数（all_listings 指定時のみ）
    """
    out = dict(listing)
    out["investment_score"] = calculate_investment_score(listing)
    dom = calculate_days_on_market(listing, reference_date)
    if dom is not None:
        out["days_on_market"] = dom
    if all_listings:
        out["competing_listings"] = count_competing_listings(listing, all_listings)
    return out


if __name__ == "__main__":
    main()
