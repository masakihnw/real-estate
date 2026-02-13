"""
10年後の資産価値と儲かる確率のシミュレーション。

price_predictor（区別係数・calibration・Yield Floor）と共通アルゴリズムを使用する。
10年後の推定時価・予測騰落率・推定含み益・儲かる確率は、すべて price_predictor の
10年後Standard予測と含み益から算出する（資産性ランクと同一ロジック）。
"""

import math
from dataclasses import dataclass
from typing import Any, Literal, Optional

# ---------------------------------------------------------------------------
# 係数（ソース統計に基づく。カスタマイズ可能な定数）
# ---------------------------------------------------------------------------

# 年間下落率の基本値（地域別）
BASE_DEPRECIATION_TOKYO_23 = 0.012   # 東京23区: 1.2%
BASE_DEPRECIATION_YOKOHAMA = 0.022   # 横浜市: 2.2%
BASE_DEPRECIATION_CHIBA = 0.028      # 千葉市: 2.8%
BASE_DEPRECIATION_OTHER = 0.028      # その他: 2.8%

# 立地補正（駅徒歩）[3]: 倍率が低いほど値下がりしにくい
LOCATION_FACTOR_WALK_5_OR_LESS = 0.8   # 5分以内
LOCATION_FACTOR_WALK_7_OR_LESS = 1.0    # 7分以内
LOCATION_FACTOR_WALK_10_OR_MORE = 1.5   # 10分超

# 規模補正（総戸数）[3]
SCALE_FACTOR_200_OR_MORE = 0.9   # 200戸以上
SCALE_FACTOR_100_OR_MORE = 0.95  # 100戸以上
SCALE_FACTOR_UNDER_50 = 1.1      # 50戸未満
# 50戸以上100戸未満: 1.0

# 面積補正 [5, 7]
SIZE_FACTOR_40_OR_MORE = 0.9   # 40㎡以上
SIZE_FACTOR_UNDER_40 = 1.2     # 40㎡未満

# 建物種別補正（タワーマンション＝20階以上想定）[4]
TYPE_FACTOR_TOWER = 0.9  # タワー: 値下がりしにくい
# 非タワー: 1.0

# ローン残高計算用（50年変動金利・金利0.8%・元利均等・10年後の残高。price_predictor と共通）
LOAN_YEARS = 50
LOAN_ANNUAL_RATE = 0.008   # 0.8%（iOS アプリと統一）
LOAN_MONTHS = LOAN_YEARS * 12  # 600
LOAN_MONTHS_AFTER_10Y = 10 * 12  # 120

# 儲かる確率の閾値（含み益／購入価格）
PROFIT_LEVEL_HIGH_RATIO = 0.10   # 含み益が購入価格の10%以上 → 高
# 0%以上10%未満 → 中
# マイナス（オーバーローン）→ 低

RegionType = Literal["tokyo_23", "yokohama", "chiba", "other_kanto"]


@dataclass
class SimulationResult:
    """10年シミュレーションの結果。"""
    price_10y_man: float          # 10年後の推定時価（万円）
    retention_rate: float         # 購入価格に対する維持率（0〜1）
    change_rate_pct: float         # 予測騰落率（%）。例: -12.0 は12%下落
    loan_residual_10y_man: float  # 10年後のローン残債（万円）
    implied_gain_man: float       # 推定含み益（万円）= 10年後時価 - 10年後ローン残債
    profit_level: Literal["高", "中", "低"]  # 儲かる確率の判定


def _get_base_depreciation(region: RegionType) -> float:
    if region == "tokyo_23":
        return BASE_DEPRECIATION_TOKYO_23
    if region == "yokohama":
        return BASE_DEPRECIATION_YOKOHAMA
    if region == "chiba":
        return BASE_DEPRECIATION_CHIBA
    return BASE_DEPRECIATION_OTHER


def _get_location_factor(walk_min: Optional[int]) -> float:
    """立地補正（徒歩分数）。5分以内0.8 / 7分以内1.0 / 10分超1.5。"""
    if walk_min is None or walk_min < 0:
        return LOCATION_FACTOR_WALK_7_OR_LESS
    if walk_min <= 5:
        return LOCATION_FACTOR_WALK_5_OR_LESS
    if walk_min <= 10:
        return LOCATION_FACTOR_WALK_7_OR_LESS
    return LOCATION_FACTOR_WALK_10_OR_MORE


def _get_scale_factor(total_units: Optional[int]) -> float:
    """規模補正（総戸数）。200戸以上0.9 / 100戸以上0.95 / 50戸未満1.1。"""
    if total_units is None:
        return 1.0
    if total_units >= 200:
        return SCALE_FACTOR_200_OR_MORE
    if total_units >= 100:
        return SCALE_FACTOR_100_OR_MORE
    if total_units < 50:
        return SCALE_FACTOR_UNDER_50
    return 1.0


def _get_size_factor(area_m2: Optional[float]) -> float:
    """面積補正。40㎡以上0.9 / 40㎡未満1.2。"""
    if area_m2 is None:
        return 1.0
    if area_m2 >= 40:
        return SIZE_FACTOR_40_OR_MORE
    return SIZE_FACTOR_UNDER_40


def _get_type_factor(is_tower: bool) -> float:
    """建物種別補正（タワーかどうか）。"""
    return TYPE_FACTOR_TOWER if is_tower else 1.0


def _calc_loan_residual_after_10y(price_man: float) -> float:
    """
    元利均等・金利1%・50年ローンで、10年後のローン残債（万円）を計算する。
    """
    if price_man <= 0:
        return 0.0
    n = LOAN_MONTHS
    r = LOAN_ANNUAL_RATE / 12
    if r <= 0:
        return price_man * (1 - LOAN_MONTHS_AFTER_10Y / n)
    # 月返済額 M = P * r * (1+r)^n / ((1+r)^n - 1)
    monthly = price_man * r * math.pow(1 + r, n) / (math.pow(1 + r, n) - 1)
    k = LOAN_MONTHS_AFTER_10Y
    # 残高 B_k = P * (1+r)^k - M * (((1+r)^k - 1) / r)
    balance = price_man * math.pow(1 + r, k) - monthly * (math.pow(1 + r, k) - 1) / r
    return max(0.0, balance)


def infer_region_from_address(address: Optional[str]) -> RegionType:
    """
    住所から地域を推定。
    東京23区 → tokyo_23、横浜市 → yokohama、千葉市 → chiba、それ以外 → other_kanto。
    """
    if not address or not address.strip():
        return "tokyo_23"
    a = address.strip()
    if "横浜市" in a:
        return "yokohama"
    if "千葉市" in a:
        return "chiba"
    tokyo_wards = (
        "千代田区", "中央区", "港区", "新宿区", "文京区", "台東区", "墨田区", "江東区",
        "品川区", "目黒区", "大田区", "世田谷区", "渋谷区", "中野区", "杉並区", "豊島区",
        "北区", "荒川区", "板橋区", "練馬区", "足立区", "葛飾区", "江戸川区",
    )
    for w in tokyo_wards:
        if w in a:
            return "tokyo_23"
    return "other_kanto"


def infer_is_tower_from_listing(listing: dict[str, Any]) -> bool:
    """
    物件名などからタワーマンションかどうかを推定。
    「タワー」を含む場合は True。階数データは未使用。
    """
    name = (listing.get("name") or "").strip()
    return "タワー" in name


def calculate_profit_probability(
    price_man: Optional[float],
    area_m2: Optional[float],
    walk_min: Optional[int],
    total_units: Optional[int],
    is_tower: bool,
    region: RegionType,
) -> SimulationResult:
    """
    沖有人氏の「資産性の法則」に基づき、10年後の資産価値と儲かる確率を算出する。

    引数（SUUMO想定）:
      price_man: 現在価格（万円）
      area_m2: 専有面積（㎡）
      walk_min: 駅徒歩分数
      total_units: 総戸数
      is_tower: タワーマンションか否か
      region: 23区 / 横浜 / 千葉 / その他

    返り値:
      SimulationResult（10年後の推定時価・予測騰落率・推定含み益・儲かる確率）
    """
    if price_man is None or price_man <= 0:
        return SimulationResult(
            price_10y_man=0.0,
            retention_rate=0.0,
            change_rate_pct=0.0,
            loan_residual_10y_man=0.0,
            implied_gain_man=0.0,
            profit_level="低",
        )

    base = _get_base_depreciation(region)
    loc = _get_location_factor(walk_min)
    scale = _get_scale_factor(total_units)
    size = _get_size_factor(area_m2)
    typ = _get_type_factor(is_tower)

    # 10年後の推定時価 = price * (1 - (BaseDepreciation * 各Factorの積) * 10)
    annual_rate = base * loc * scale * size * typ
    total_depreciation = min(annual_rate * 10, 0.99)
    retention = 1.0 - total_depreciation
    price_10y = price_man * retention
    change_pct = (retention - 1.0) * 100

    # 10年後のローン残債（50年・金利1%・元利均等・頭金0）
    loan_residual_10y = _calc_loan_residual_after_10y(price_man)

    # 含み益 = 10年後の推定時価 - 10年後のローン残債
    implied_gain = price_10y - loan_residual_10y

    # 儲かる確率: 高＝含み益が購入価格の10%以上 / 中＝0%以上10%未満 / 低＝マイナス
    gain_ratio = implied_gain / price_man if price_man else 0.0
    if gain_ratio >= PROFIT_LEVEL_HIGH_RATIO:
        profit_level: Literal["高", "中", "低"] = "高"
    elif implied_gain >= 0:
        profit_level = "中"
    else:
        profit_level = "低"

    return SimulationResult(
        price_10y_man=round(price_10y, 1),
        retention_rate=round(retention, 4),
        change_rate_pct=round(change_pct, 1),
        loan_residual_10y_man=round(loan_residual_10y, 1),
        implied_gain_man=round(implied_gain, 1),
        profit_level=profit_level,
    )


# 後方互換のエイリアス
def simulate_10year(
    price_man: Optional[float],
    area_m2: Optional[float],
    walk_min: Optional[int],
    total_units: Optional[int],
    is_tower: bool,
    region: RegionType,
) -> SimulationResult:
    """calculate_profit_probability のエイリアス。"""
    return calculate_profit_probability(
        price_man=price_man,
        area_m2=area_m2,
        walk_min=walk_min,
        total_units=total_units,
        is_tower=is_tower,
        region=region,
    )


def simulate_10year_from_listing(
    listing: dict[str, Any],
    predictor: Optional["MansionPricePredictor"] = None,
) -> SimulationResult:
    """
    物件辞書から10年シミュレーションを実行する。

    price_predictor の 10年後Standard予測・含み益・儲を使い、
    10年後の値上がり試算と資産性ランクと同一の数値を返す。

    Args:
        listing: 物件辞書
        predictor: 省略時は新規作成して load_data() を呼ぶ。
                  複数物件をループ処理する場合は事前に作成して渡すと CSV の重複読込を回避できる。
    """
    from price_predictor import MansionPricePredictor, listing_to_property_data

    if predictor is None:
        predictor = MansionPricePredictor()
        predictor.load_data()
    prop = listing_to_property_data(listing)
    result = predictor.predict(prop)

    contract_yen = result.get("current_estimated_contract_price") or 0
    forecast = result.get("10y_forecast") or {}
    std_yen = forecast.get("standard") or 0
    implied_gain_yen = result.get("implied_gain_yen")
    profit_level = result.get("profit_level", "低")

    if contract_yen <= 0 or std_yen <= 0:
        return SimulationResult(
            price_10y_man=0.0,
            retention_rate=0.0,
            change_rate_pct=0.0,
            loan_residual_10y_man=0.0,
            implied_gain_man=0.0,
            profit_level="低",
        )

    contract_man = contract_yen / 10000
    price_10y_man = std_yen / 10000
    retention_rate = std_yen / contract_yen
    change_rate_pct = (retention_rate - 1.0) * 100
    loan_residual_10y_man = _calc_loan_residual_after_10y(contract_man)
    implied_gain_man = (implied_gain_yen / 10000) if implied_gain_yen is not None else (price_10y_man - loan_residual_10y_man)

    return SimulationResult(
        price_10y_man=round(price_10y_man, 1),
        retention_rate=round(retention_rate, 4),
        change_rate_pct=round(change_rate_pct, 1),
        loan_residual_10y_man=round(loan_residual_10y_man, 1),
        implied_gain_man=round(implied_gain_man, 1),
        profit_level=profit_level,
    )


def simulate_batch(listings: list[dict[str, Any]]) -> list[SimulationResult]:
    """
    複数物件を一度にシミュレーション（Predictor を使い回す）。
    CSV の読込は1回のみで済むため、ループ処理より効率的。
    """
    from price_predictor import MansionPricePredictor

    predictor = MansionPricePredictor()
    predictor.load_data()
    return [simulate_10year_from_listing(listing, predictor=predictor) for listing in listings]


def format_implied_gain(implied_gain_man: Optional[float]) -> str:
    """推定含み益をレポート用文字列に。"""
    if implied_gain_man is None:
        return "-"
    if implied_gain_man <= -10000:
        oku = int(-(-implied_gain_man // 10000))
        man = int(abs(implied_gain_man) % 10000)
        return f"-{oku}億{man}万円" if man else f"-{oku}億円"
    if implied_gain_man >= 10000:
        oku = int(implied_gain_man // 10000)
        man = int(implied_gain_man % 10000)
        return f"{oku}億{man}万円" if man else f"{oku}億円"
    if implied_gain_man >= 0:
        return f"+{int(implied_gain_man)}万円"
    return f"{int(implied_gain_man)}万円"


def format_simulation_for_report(sim: SimulationResult) -> tuple[str, str, str, str]:
    """
    レポート用の表示文字列を返す。
    (10年後価格, 予測騰落率, 推定含み益, 儲かる確率)
    """
    if sim.price_10y_man <= 0 and sim.implied_gain_man == 0:
        return "-", "-", "-", getattr(sim, "profit_level", "低")
    # 10年後価格
    if sim.price_10y_man >= 10000:
        oku = int(sim.price_10y_man // 10000)
        man = int(sim.price_10y_man % 10000)
        price_str = f"{oku}億{man}万円" if man else f"{oku}億円"
    else:
        price_str = f"{int(sim.price_10y_man)}万円"
    change_str = f"{sim.change_rate_pct:+.1f}%"
    implied_str = format_implied_gain(sim.implied_gain_man)
    return price_str, change_str, implied_str, sim.profit_level
