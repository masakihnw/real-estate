"""
2026年1月時点の経済予測に基づく「3つの未来シナリオ」でマンション10年後価格を予測するクラス。

収益還元法（インカム）と原価法（コスト）のハイブリッドで算出し、高い方を採用。
ユーザーが macro_scenarios を設定可能。デフォルトは最新2026年予測レポートに基づく。
"""

from __future__ import annotations

import math
import re
from pathlib import Path
from typing import Any, Literal, Optional

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
WARD_POTENTIAL_PATH = DATA_DIR / "ward_potential.csv"

# 売り出し→成約補正（東京カンテイ 2024下期乖離率）
LISTING_TO_CONTRACT_RATIO = 0.958
CURRENT_YEAR = 2026
CURRENT_INTEREST_RATE = 0.01  # 現在金利1%

# 賃料成長ポテンシャル別の係数（S=1.2倍, A=1.0, B=0.9, C=0.8）
RENT_GROWTH_COEF = {"S": 1.2, "A": 1.0, "B": 0.9, "C": 0.8}
# 金利感応度 β_area（都心0.8, 郊外1.2）。S/A=都心, B/C=郊外
INTEREST_SENSITIVITY = {"S": 0.8, "A": 0.8, "B": 1.2, "C": 1.2}
# ベースキャップレート（都心3.5%, 準都心4%, 郊外4.5%）
CAP_RATE_BY_RANK = {"S": 0.035, "A": 0.04, "B": 0.045, "C": 0.045}

# 土地・建物の割合（東京23区想定）
LAND_RATIO = 0.65
BUILDING_RATIO = 0.35
# 建物の年間減価率（築浅・大規模時は実質ゼロに補正）
BASE_ANNUAL_DEPRECIATION = 0.012
# 築浅・大規模の閾値（築10年以内かつ200戸以上で減価実質ゼロ）
NEWBUILD_AGE_MAX = 10
LARGE_SCALE_UNITS = 200

# 2026年市場補正
BONUS_15MIN_WARDS = {"江東区", "墨田区", "品川区"}  # 都心15分ずらし＋駅近5分
PENALTY_TIER1_WARDS = {"港区", "中央区", "千代田区"}  # 都心3区・1.5億以上
PENALTY_PRICE_THRESHOLD_YEN = 150_000_000
BONUS_15MIN_PCT = 0.05
PENALTY_INVENTORY_PCT = 0.05
ZEH_RENOVATION_BONUS_PCT = 0.02
ZEH_RENOVATION_KEYWORDS = ["ZEH", "省エネ", "断熱", "リノベーション済", "リフォーム済"]

# 含み益率→資産性ランク（10%以上S, 5%以上A, 0%以上B, 未満C）
IMPLIED_GAIN_RATIO_S = 0.10
IMPLIED_GAIN_RATIO_A = 0.05
IMPLIED_GAIN_RATIO_B = 0.0
LOAN_YEARS = 50
LOAN_MONTHS_AFTER_10Y = 10 * 12


DEFAULT_MACRO_SCENARIOS = {
    "optimistic": {
        "cpi_rate": 0.025,
        "rent_increase": 0.04,
        "interest_rate_10y": 0.015,
        "construction_cost": 0.05,
    },
    "neutral": {
        "cpi_rate": 0.02,
        "rent_increase": 0.02,
        "interest_rate_10y": 0.025,
        "construction_cost": 0.03,
    },
    "pessimistic": {
        "cpi_rate": 0.01,
        "rent_increase": 0.005,
        "interest_rate_10y": 0.04,
        "construction_cost": 0.01,
    },
}


def _ward_from_address(address: Optional[str]) -> Optional[str]:
    """住所から区名を抽出。"""
    if not address or not str(address).strip():
        return None
    s = str(address).strip()
    m = re.search(r"(?:東京都)?([一-龥ぁ-んァ-ン]+区)", s)
    if m:
        return m.group(1).strip()
    return None


def _calc_loan_residual_10y_yen(price_yen: float) -> float:
    """50年変動金利・金利1%・元利均等で10年後のローン残高（円）。"""
    if price_yen <= 0:
        return 0.0
    price_man = price_yen / 10000
    n = LOAN_YEARS * 12
    r = CURRENT_INTEREST_RATE / 12
    if r <= 0:
        return price_yen * (1 - LOAN_MONTHS_AFTER_10Y / n)
    monthly = price_man * r * math.pow(1 + r, n) / (math.pow(1 + r, n) - 1)
    k = LOAN_MONTHS_AFTER_10Y
    balance_man = price_man * math.pow(1 + r, k) - monthly * (math.pow(1 + r, k) - 1) / r
    return max(0.0, balance_man) * 10000


def _implied_gain_to_grade(implied_gain_ratio: float) -> str:
    """含み益率から投資グレード S/A/B/C。"""
    if implied_gain_ratio >= IMPLIED_GAIN_RATIO_S:
        return "S"
    if implied_gain_ratio >= IMPLIED_GAIN_RATIO_A:
        return "A"
    if implied_gain_ratio >= IMPLIED_GAIN_RATIO_B:
        return "B"
    return "C"


class FutureEstatePredictor:
    """
    3つのマクロシナリオ（楽観・中立・悲観）に応じて10年後価格を予測するクラス。
    収益還元法と原価法の両方で算出し、高い方を採用。2026年市場補正を適用。
    """

    def __init__(
        self,
        macro_scenarios: Optional[dict[str, dict[str, float]]] = None,
        data_dir: Optional[Path] = None,
    ):
        self.macro_scenarios = macro_scenarios or DEFAULT_MACRO_SCENARIOS.copy()
        self.data_dir = Path(data_dir) if data_dir else DATA_DIR
        self._ward_potential: Optional[pd.DataFrame] = None
        self._loaded = False

    def _load_ward_potential(self) -> None:
        path = self.data_dir / "ward_potential.csv"
        if not path.exists():
            self._ward_potential = None
            self._loaded = True
            return
        self._ward_potential = pd.read_csv(path, encoding="utf-8")
        self._ward_potential["ward_name"] = self._ward_potential["ward_name"].astype(str).str.strip()
        if "supply_constraint" in self._ward_potential.columns:
            self._ward_potential["supply_constraint"] = pd.to_numeric(
                self._ward_potential["supply_constraint"], errors="coerce"
            ).fillna(1.0)
        self._loaded = True

    def _ensure_loaded(self) -> None:
        if not self._loaded:
            self._load_ward_potential()

    def _get_ward_params(self, ward_name: Optional[str]) -> tuple[str, float]:
        """区名から賃料成長ポテンシャル(S/A/B/C)と供給制約係数を返す。"""
        self._ensure_loaded()
        rank = "C"
        supply_constraint = 1.0
        if ward_name and self._ward_potential is not None:
            match = self._ward_potential[
                self._ward_potential["ward_name"].astype(str).str.strip() == ward_name.strip()
            ]
            if not match.empty:
                row = match.iloc[0]
                rank = str(row.get("rent_growth_potential", "C")).strip().upper()
                if rank not in ("S", "A", "B", "C"):
                    rank = "C"
                supply_constraint = float(row.get("supply_constraint", 1.0))
        return rank, supply_constraint

    def _estimate_current_rent(self, property_data: dict[str, Any], rank: str) -> float:
        """現行賃料。未設定時は成約推定価格×キャップレートから逆算。"""
        current_rent = property_data.get("current_rent")
        if current_rent is not None and current_rent != "" and float(current_rent) > 0:
            return float(current_rent)
        listing_price = property_data.get("listing_price")
        if listing_price is None or listing_price == "":
            price_man = property_data.get("price_man")
            if price_man is not None and price_man != "":
                listing_price = float(price_man) * 10000
            else:
                return 0.0
        listing_yen = float(listing_price)
        if listing_yen <= 0:
            return 0.0
        contract_yen = listing_yen * LISTING_TO_CONTRACT_RATIO
        cap = CAP_RATE_BY_RANK.get(rank, 0.045)
        annual_rent = contract_yen * cap
        return annual_rent / 12  # 月額

    def _calculate_income_price(
        self,
        property_data: dict[str, Any],
        scenario: dict[str, float],
        rank: str,
        current_rent_monthly: float,
    ) -> float:
        """
        収益還元法: Price_10y = (Rent_current * 12 * (1+R_rent)^10) / (CapRate_base + (R_interest × β_area))
        R_rent = シナリオ家賃上昇率 × エリア係数(S=1.2, C=0.8等)
        R_interest = シナリオ10年後金利 - 現在金利
        """
        if current_rent_monthly <= 0:
            return 0.0
        rent_increase = float(scenario.get("rent_increase", 0.02))
        interest_10y = float(scenario.get("interest_rate_10y", 0.025))
        area_coef = RENT_GROWTH_COEF.get(rank, 0.9)
        r_rent = rent_increase * area_coef
        r_interest = interest_10y - CURRENT_INTEREST_RATE
        beta = INTEREST_SENSITIVITY.get(rank, 1.2)
        cap_base = CAP_RATE_BY_RANK.get(rank, 0.045)
        cap_10y = cap_base + (r_interest * beta)
        cap_10y = max(0.01, min(0.15, cap_10y))  # クリップ
        rent_10y_annual = current_rent_monthly * 12 * np.power(1.0 + r_rent, 10)
        price_10y = rent_10y_annual / cap_10y
        return float(price_10y)

    def _calculate_cost_price(
        self,
        property_data: dict[str, Any],
        scenario: dict[str, float],
        current_valuation_yen: float,
        supply_constraint: float,
    ) -> float:
        """
        原価法: Price_10y = (LandPrice×1.05) + (BuildingPrice×(1−Dep)×(1+R_const)^10)
        築浅・大規模は減価Depを実質ゼロに補正。
        """
        if current_valuation_yen <= 0:
            return 0.0
        build_year = property_data.get("build_year") or property_data.get("built_year")
        total_units = property_data.get("total_units")
        if total_units is not None and total_units != "":
            total_units = int(total_units)
        else:
            total_units = None
        age_years = CURRENT_YEAR - int(build_year) if build_year is not None else 15
        # 築浅・大規模なら減価実質ゼロ
        if age_years <= NEWBUILD_AGE_MAX and (total_units or 0) >= LARGE_SCALE_UNITS:
            dep_factor = 1.0
        else:
            total_dep = min(BASE_ANNUAL_DEPRECIATION * 10, 0.99)
            dep_factor = 1.0 - total_dep
        r_const = float(scenario.get("construction_cost", 0.03))
        land_price = current_valuation_yen * LAND_RATIO
        building_price = current_valuation_yen * BUILDING_RATIO
        price_10y = land_price * 1.05 + building_price * dep_factor * np.power(1.0 + r_const, 10)
        price_10y *= supply_constraint  # 供給制約で中古価格維持
        return float(price_10y)

    def _apply_2026_corrections(
        self,
        price_10y: float,
        property_data: dict[str, Any],
        ward_name: Optional[str],
    ) -> float:
        """15分ずらし+5%、都心3区1.5億以上-5%、ZEH/リノベ+2%。"""
        p = price_10y
        walk_min = property_data.get("walk_min")
        if walk_min is not None and walk_min != "":
            walk_min = int(walk_min)
        else:
            walk_min = 99
        if ward_name and ward_name in BONUS_15MIN_WARDS and walk_min <= 5:
            p *= 1.0 + BONUS_15MIN_PCT
        if ward_name and ward_name in PENALTY_TIER1_WARDS and p >= PENALTY_PRICE_THRESHOLD_YEN:
            p *= 1.0 - PENALTY_INVENTORY_PCT
        text_parts = []
        for key in ("notes", "features", "description", "remarks", "備考", "特徴"):
            val = property_data.get(key)
            if val is not None and isinstance(val, str):
                text_parts.append(val)
        combined = " ".join(text_parts)
        if any(kw in combined for kw in ZEH_RENOVATION_KEYWORDS):
            p *= 1.0 + ZEH_RENOVATION_BONUS_PCT
        return p

    def predict(self, property_data: dict[str, Any]) -> dict[str, Any]:
        """
        物件データとマクロシナリオから10年後価格を予測する。

        返り値:
          - current_valuation: 乖離率補正後の現在価値（円）
          - forecast_2035: { optimistic, neutral, pessimistic } 各 price, change_rate, driver
          - investment_grade: S/A/B/C
          - strategic_advice: 戦略アドバイス
        """
        self._ensure_loaded()
        listing_price = property_data.get("listing_price")
        if listing_price is None or listing_price == "":
            price_man = property_data.get("price_man")
            if price_man is not None and price_man != "":
                listing_price = float(price_man) * 10000
            else:
                listing_price = 0.0
        listing_yen = float(listing_price)
        if listing_yen <= 0:
            return {
                "current_valuation": 0,
                "forecast_2035": {
                    "optimistic": {"price": 0, "change_rate": "0%", "driver": "価格情報なし"},
                    "neutral": {"price": 0, "change_rate": "0%", "driver": "価格情報なし"},
                    "pessimistic": {"price": 0, "change_rate": "0%", "driver": "価格情報なし"},
                },
                "investment_grade": "C",
                "strategic_advice": "価格情報がありません。",
            }
        address = property_data.get("ss_address") or property_data.get("address") or property_data.get("住所") or property_data.get("addr")
        ward_name = _ward_from_address(address) or property_data.get("ward")
        rank, supply_constraint = self._get_ward_params(ward_name)
        current_valuation = int(round(listing_yen * LISTING_TO_CONTRACT_RATIO))
        current_rent = self._estimate_current_rent(property_data, rank)

        forecast_2035: dict[str, dict[str, Any]] = {}
        drivers = {
            "optimistic": "賃料50%上昇と建築費高騰によるインフレヘッジ",
            "neutral": "金利上昇を賃料増が相殺し、横ばい〜微増",
            "pessimistic": "金利4%到達によるキャップレート上昇・購買力低下",
        }
        for scenario_id, scenario in self.macro_scenarios.items():
            income_p = self._calculate_income_price(
                property_data, scenario, rank, current_rent
            )
            cost_p = self._calculate_cost_price(
                property_data, scenario, current_valuation, supply_constraint
            )
            price_10y = max(income_p, cost_p)
            price_10y = self._apply_2026_corrections(price_10y, property_data, ward_name)
            price_10y = max(0, int(round(price_10y)))
            change = (price_10y / current_valuation - 1.0) * 100 if current_valuation else 0
            change_str = f"{change:+.1f}%"
            forecast_2035[scenario_id] = {
                "price": price_10y,
                "change_rate": change_str,
                "driver": drivers.get(scenario_id, ""),
            }

        # 資産性ランクは neutral シナリオの含み益率で判定
        neutral_price = forecast_2035.get("neutral", {}).get("price") or 0
        loan_residual = _calc_loan_residual_10y_yen(current_valuation)
        implied_gain_yen = neutral_price - loan_residual
        implied_gain_ratio = implied_gain_yen / current_valuation if current_valuation else 0.0
        investment_grade = _implied_gain_to_grade(implied_gain_ratio)

        # 戦略アドバイス
        if implied_gain_ratio >= IMPLIED_GAIN_RATIO_A:
            strategic_advice = "2030年までの賃料急騰期に保有推奨。金利4%シナリオでも残債割れリスク低。"
        elif implied_gain_ratio >= IMPLIED_GAIN_RATIO_B:
            strategic_advice = "中立シナリオで含み益が見込める。金利上昇時は価格変動に注意。"
        else:
            strategic_advice = "金利・賃料の悪化シナリオでは残債割れリスクあり。慎重な検討を推奨。"

        return {
            "current_valuation": current_valuation,
            "forecast_2035": forecast_2035,
            "investment_grade": investment_grade,
            "strategic_advice": strategic_advice,
            "implied_gain_yen": int(round(implied_gain_yen)),
            "implied_gain_ratio": round(implied_gain_ratio, 4),
        }
