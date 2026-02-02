"""
物件の資産性ランク（S/A/B/C）を付与する。

10年後の値上がり試算（price_predictor）と共通アルゴリズムを使用する。
資産性の本質＝含み益がどれだけ出るか、に基づき、
price_predictor の 10年後Standard予測とローン残債から算出した含み益率でランクを決定する。
"""

from typing import Any, Optional

# ランク閾値（含み益率。price_predictor の IMPLIED_GAIN_RATIO_* と一致）
RANK_S_MIN_RATIO = 0.10   # 10%以上でS
RANK_A_MIN_RATIO = 0.05   # 5%以上でA
RANK_B_MIN_RATIO = 0.0    # 0%以上でB
# 未満: C

# 予測器のシングルトン（load_data を1回だけ実行するため）
_predictor: Any = None


def _get_predictor():
    global _predictor
    if _predictor is None:
        from price_predictor import MansionPricePredictor
        _predictor = MansionPricePredictor()
        _predictor.load_data()
    return _predictor


def get_asset_score_and_rank(
    listing: dict[str, Any],
    *,
    built_year_min: Optional[int] = None,
    current_year: Optional[int] = None,
    walk_max: int = 7,
    total_units_min: int = 100,
) -> tuple[float, str]:
    """
    1物件の資産性スコア（0-100）とランク（S/A/B/C）を返す。

    price_predictor の 10年後Standard予測と含み益率を用いる。
    含み益率 = (10年後Standard価格 - 10年後ローン残債) / 現在成約推定価格。
    10%以上→S, 5%以上→A, 0%以上→B, 未満→C。
    """
    from price_predictor import listing_to_property_data, implied_gain_ratio_to_asset_rank

    predictor = _get_predictor()
    prop = listing_to_property_data(listing)
    result = predictor.predict(prop)
    ratio = result.get("implied_gain_ratio")
    if ratio is None:
        return 0.0, "C"
    return implied_gain_ratio_to_asset_rank(float(ratio))


def get_asset_score_and_rank_with_breakdown(
    listing: dict[str, Any],
    **kwargs: Any,
) -> tuple[float, str, str]:
    """
    1物件の資産性スコア・ランク・根拠文字列を返す。
    根拠は「含み益率X%」（10年後Standard予測ベース）で統一。
    """
    from price_predictor import listing_to_property_data, implied_gain_ratio_to_asset_rank

    predictor = _get_predictor()
    prop = listing_to_property_data(listing)
    result = predictor.predict(prop)
    ratio = result.get("implied_gain_ratio")
    if ratio is None:
        return 0.0, "C", "含み益率-"
    score, rank = implied_gain_ratio_to_asset_rank(float(ratio))
    pct = float(ratio) * 100
    breakdown = f"含み益率{pct:+.1f}%"
    return score, rank, breakdown
