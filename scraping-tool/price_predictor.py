"""
10年後の成約価格を予測する MansionPricePredictor。

SUUMO/HOMES の掲載情報と外部係数データ（CSV）を組み合わせ、
ルールベースで3シナリオ（Standard / Best / Worst）を算出する。
将来の XGBoost 等組み込みを想定した構造化をしている。
"""

from __future__ import annotations

import json
import math
import re
from pathlib import Path
from typing import Any, Literal, Optional

import pandas as pd

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"
CALIBRATION_PATH = DATA_DIR / "calibration.json"

# ステップ1: 売り出し→成約補正（東京カンテイ 2024下期乖離率 -4.19%）
LISTING_TO_CONTRACT_RATIO = 0.958
# 価格帯別流動性ペナルティ（1.2億〜1.5億: -2%, 1.5億〜3億: -5%, 3億以上: なし）
WALL_120M_YEN = 120_000_000
WALL_150M_YEN = 150_000_000
WALL_300M_YEN = 300_000_000
LIQUIDITY_PENALTY_120_150 = 0.98   # 1.2億〜1.5億: -2%
LIQUIDITY_PENALTY_150_300 = 0.95   # 1.5億〜3億: -5%
# 在庫・需給バランス
INVENTORY_OVER_THRESHOLD = 1.1     # 在庫過多
INVENTORY_UNDER_THRESHOLD = 0.95   # 品薄
INVENTORY_DOWNSIDE_FACTOR = 0.5    # 在庫過多時の減額係数（粘着性考慮で半分）
INVENTORY_UP_BONUS = 0.02          # 品薄時 +2%
# 省エネ・リノベ付加価値
ZEH_RENOVATION_KEYWORDS = ["ZEH", "省エネ", "断熱", "リノベーション済", "リフォーム済"]
ZEH_RENOVATION_BONUS_PCT = 0.015   # +1.5%
# Bestシナリオ抑制（都心1億円以上・外国人規制考慮）
FOREIGN_REGULATION_TIER1_MIN_YEN = 100_000_000
BEST_SCENARIO_TIER1_HIGH_SUPPRESS = 0.95

# ステップ2: ベースライン経年減価（年間減価率）
BASE_ANNUAL_DEPRECIATION = 0.012  # 1.2%
TIER1_DEPRECIATION_MITIGATION = 0.5  # Tier1は50%緩和 → 0.6%

# ステップ3: 個別要因
MANAGEMENT_DEFICIT_MAX_PCT = -0.15  # 修繕積立金不足 最大-15%
AREA_40_50_BONUS_PCT = 0.03  # 40以上50未満 +3%（2026年改正で中古40㎡以上が減税対象）
WALK_THRESHOLD_MIN = 7  # 徒歩7分以内は減価なし
CURRENT_YEAR = 2026

# 賃料・利回り（推定賃料逆算・Yield Floor用）
CAP_RATE_TIER1 = 0.035   # 都心 3.5%
CAP_RATE_TIER2 = 0.04    # 準都心 4%
CAP_RATE_TIER3 = 0.045   # 郊外 4.5%
# 賃料成長率は area_coefficients.csv の rent_growth_rate を使用。未定義時用デフォルト
DEFAULT_RENT_GROWTH = 1.05

# 金利上昇感応度（Standard/Worstに適用）。Tier3は2025年12月利上げを反映して厳格化
INTEREST_SENSITIVITY_TIER1 = 1.0   # 都心: 影響なし
INTEREST_SENSITIVITY_TIER2 = 0.98  # 準都心: -2%
INTEREST_SENSITIVITY_TIER3 = 0.92  # 郊外: -8%（頭打ち・実需ローン負担増を反映）

# タワマン・大規模ボーナス／高さ制限エリアのトレンド抑制
TOWER_LARGE_BONUS_PCT = 0.03       # タワマン適性エリアかつ大規模時 +3%
TOWER_TREND_SUPPRESS = 0.98        # 高さ制限エリアで非大規模時のトレンド係数
TOWER_LARGE_UNITS_THRESHOLD = 200  # 総戸数これ以上で「大規模」
TOWER_LARGE_FLOOR_THRESHOLD = 20   # 階数これ以上で「タワマン規模」

# 災害リスクペナルティ（2028年レッドゾーン減税除外を見据え）
HAZARD_PENALTY_RED = 0.90    # hazard_risk==2: -10%
HAZARD_PENALTY_YELLOW = 0.97  # hazard_risk==1: -3%

# 含み益・資産性ランク用（50年変動金利・金利1%・元利均等・10年後の残高。レポート月額表示と共通前提）
LOAN_YEARS = 50
LOAN_ANNUAL_RATE = 0.01
LOAN_MONTHS = LOAN_YEARS * 12
LOAN_MONTHS_AFTER_10Y = 10 * 12
# 儲かる確率: 含み益率10%以上→高, 0%以上10%未満→中, マイナス→低
IMPLIED_GAIN_RATIO_S = 0.10   # 含み益率10%以上で資産性S
IMPLIED_GAIN_RATIO_A = 0.05   # 5%以上でA
IMPLIED_GAIN_RATIO_B = 0.0    # 0%以上でB, 未満でC


def _calc_loan_residual_10y_yen(price_yen: float) -> float:
    """
    元利均等・金利1%・50年ローンで、10年後のローン残高（円）を返す。
    資産性ランク・含み益算出の共通前提（asset_simulation と同一ロジック）。
    """
    if price_yen <= 0:
        return 0.0
    price_man = price_yen / 10000
    n = LOAN_MONTHS
    r = LOAN_ANNUAL_RATE / 12
    if r <= 0:
        return price_yen * (1 - LOAN_MONTHS_AFTER_10Y / n)
    monthly = price_man * r * math.pow(1 + r, n) / (math.pow(1 + r, n) - 1)
    k = LOAN_MONTHS_AFTER_10Y
    balance_man = price_man * math.pow(1 + r, k) - monthly * (math.pow(1 + r, k) - 1) / r
    return max(0.0, balance_man) * 10000


def implied_gain_ratio_to_asset_rank(implied_gain_ratio: float) -> tuple[float, str]:
    """
    含み益率（10年後Standard価格に対する割合）から資産性スコア(0-100)とランク(S/A/B/C)を返す。
    資産性の本質＝含み益がどれだけ出るか、に基づく共通アルゴリズム。
    10%以上S, 5%以上A, 0%以上B, 未満C。スコアは含み益率を0-100にマッピング（0%→0, 10%→100）。
    """
    if implied_gain_ratio >= IMPLIED_GAIN_RATIO_S:
        rank = "S"
    elif implied_gain_ratio >= IMPLIED_GAIN_RATIO_A:
        rank = "A"
    elif implied_gain_ratio >= IMPLIED_GAIN_RATIO_B:
        rank = "B"
    else:
        rank = "C"
    score = min(100.0, max(0.0, implied_gain_ratio * 1000))
    return round(score, 1), rank


def _station_name_from_listing(station_raw: Optional[str], station_line: Optional[str]) -> Optional[str]:
    """listing の station_name または station_line から駅名を1つ取得。"""
    if station_raw and str(station_raw).strip():
        return str(station_raw).strip()
    if not station_line or not str(station_line).strip():
        return None
    m = re.search(r"[「『]([^」』]+)[」』]", str(station_line))
    if m:
        return m.group(1).strip()
    # 〇〇駅 形式
    m = re.search(r"([^\s/]+駅)", str(station_line))
    if m:
        return m.group(1).strip()
    return (str(station_line).strip()[:30] or "").strip() or None


def _listing_price_yen(property_data: dict[str, Any]) -> Optional[float]:
    """円建ての売り出し価格を返す。price_man のみの場合は万円→円に変換。"""
    listing = property_data.get("listing_price")
    if listing is not None and listing != "":
        return float(listing)
    man = property_data.get("price_man")
    if man is not None and man != "":
        return float(man) * 10000
    return None


def _clip(x: float, lo: float, hi: float) -> float:
    return max(lo, min(hi, x))


# 築10年以内の「新築同等性」ボーナス（経年減価20%緩和）
NEWBUILD_PARITY_AGE_MAX = 10
NEWBUILD_PARITY_DEPRECIATION_MITIGATION = 0.2  # 20%緩和

# エリアポテンシャル×物件属性（区別）
TOWER_POTENTIAL_BONUS_PCT = 0.05   # 大規模かつ tower_potential_flag==1 で +5%
TOWER_NO_POTENTIAL_PENALTY_PCT = -0.02  # 小規模・低層かつ tower_potential_flag==0 で -2%


def _ward_from_address(address: Optional[str]) -> Optional[str]:
    """
    住所文字列から区名（〇〇区）を抽出する。
    例: "東京都千代田区神田神保町1-1" → "千代田区", "江東区豊洲3-2" → "江東区"
    """
    if not address or not str(address).strip():
        return None
    s = str(address).strip()
    # 東京都〇〇区 / 〇〇区 のパターン（区名は漢字1〜4文字程度）
    m = re.search(r"(?:東京都)?([一-龥ぁ-んァ-ン]+区)", s)
    if m:
        return m.group(1).strip()
    return None


class MansionPricePredictor:
    """
    掲載情報と外部CSVから10年後の成約価格を予測するクラス。
    calibration.json で係数を外出しし、評価→更新可能。
    """

    def __init__(self, data_dir: Optional[Path] = None, calibration_path: Optional[Path] = None):
        self.data_dir = Path(data_dir) if data_dir else DATA_DIR
        self._calibration_path = Path(calibration_path) if calibration_path else (self.data_dir / "calibration.json")
        self._calibration: dict[str, Any] = {}
        self._ward_coefficients: Optional[pd.DataFrame] = None
        self._management_guidelines: Optional[pd.DataFrame] = None
        self._macro_scenarios: Optional[pd.DataFrame] = None
        self._loaded = False

    def _load_calibration(self) -> None:
        if self._calibration_path.exists():
            with open(self._calibration_path, encoding="utf-8") as f:
                self._calibration = json.load(f)
        else:
            self._calibration = {}

    def _cal(self, key: str, default: Any) -> Any:
        if not self._calibration:
            self._load_calibration()
        return self._calibration.get(key, default)

    def load_data(self) -> None:
        """外部CSVを読み込み、予測に使うデータを保持する。区単位の係数は ward_coefficients.csv（5賃料成長グループ・在庫スコア・高さ制限フラグ）。"""
        ward_path = self.data_dir / "ward_coefficients.csv"
        if ward_path.exists():
            self._ward_coefficients = pd.read_csv(ward_path, encoding="utf-8")
            self._ward_coefficients["ward_name"] = self._ward_coefficients["ward_name"].astype(str).str.strip()
            for col in ("rent_cagr", "inventory_trend_score", "market_momentum_score"):
                if col in self._ward_coefficients.columns:
                    default = 0.035 if col == "rent_cagr" else 1.0
                    self._ward_coefficients[col] = pd.to_numeric(
                        self._ward_coefficients[col], errors="coerce"
                    ).fillna(default)
            for col in ("rent_cluster_group", "tower_regulation_flag", "tower_potential_flag"):
                if col in self._ward_coefficients.columns:
                    self._ward_coefficients[col] = pd.to_numeric(
                        self._ward_coefficients[col], errors="coerce"
                    ).fillna(0).astype(int)
        else:
            self._ward_coefficients = None
        self._management_guidelines = pd.read_csv(
            self.data_dir / "management_guidelines.csv",
            encoding="utf-8",
            dtype={"age_min": "int64", "age_max": "int64", "guideline_yen_per_sqm": "float64"},
        )
        self._macro_scenarios = pd.read_csv(
            self.data_dir / "macro_economic_scenarios.csv",
            encoding="utf-8",
            dtype={"scenario_id": str, "scenario_name": str, "price_multiplier": "float64"},
        )
        self._loaded = True

    def _ensure_loaded(self) -> None:
        if not self._loaded:
            self.load_data()

    def _calculate_yield_floor(self, rent_monthly: float, cap_rate: float) -> float:
        """
        収益還元価格（推定賃料 ÷ キャップレート）を算出し、Worstシナリオの下値支持価格とする。
        rent_monthly: 月額賃料（円）。10年後賃料を渡す想定。
        cap_rate: キャップレート（年利回り。例: 0.035 = 3.5%）
        """
        if cap_rate <= 0:
            return 0.0
        annual_rent = rent_monthly * 12
        return annual_rent / cap_rate

    def preprocess(self, property_data: dict[str, Any]) -> dict[str, Any]:
        """
        特徴量を生成する。
        入力は listing_price(円)/station_name/... または price_man(万円)/station_line/... の両対応。
        """
        self._ensure_loaded()
        listing_price = _listing_price_yen(property_data)
        station_name = _station_name_from_listing(
            property_data.get("station_name"),
            property_data.get("station_line"),
        )
        walk_min = property_data.get("walk_min")
        if walk_min is not None and walk_min != "":
            walk_min = int(walk_min)
        else:
            walk_min = None
        area_sqm = property_data.get("area_sqm") or property_data.get("area_m2")
        if area_sqm is not None and area_sqm != "":
            area_sqm = float(area_sqm)
        else:
            area_sqm = None
        build_year = property_data.get("build_year") or property_data.get("built_year")
        if build_year is not None and build_year != "":
            build_year = int(build_year)
        else:
            build_year = None
        repair_reserve_fund = property_data.get("repair_reserve_fund")
        if repair_reserve_fund is not None and repair_reserve_fund != "":
            repair_reserve_fund = int(repair_reserve_fund)
        else:
            repair_reserve_fund = None
        management_fee = property_data.get("management_fee")
        if management_fee is not None and management_fee != "":
            management_fee = int(management_fee)
        else:
            management_fee = None
        total_units = property_data.get("total_units")
        if total_units is not None and total_units != "":
            total_units = int(total_units)
        else:
            total_units = None
        floor = property_data.get("floor") or property_data.get("floor_position")
        if floor is not None and floor != "":
            floor = int(floor)
        else:
            floor = None
        # 推定月額賃料（入力がなければ後で利回りから逆算）
        estimated_rent = property_data.get("estimated_rent")
        if estimated_rent is not None and estimated_rent != "":
            estimated_rent = float(estimated_rent)
        else:
            estimated_rent = None
        # 災害リスクフラグ（0:なし, 1:イエロー, 2:レッド）
        hazard_risk = property_data.get("hazard_risk")
        if hazard_risk is not None and hazard_risk != "":
            hazard_risk = int(hazard_risk)
        else:
            hazard_risk = 0
        # 住所（区名判定用。ss_address / address / 住所 等）
        address = property_data.get("ss_address") or property_data.get("address") or property_data.get("住所") or property_data.get("addr")

        # 築年数（現在時点）
        age_years: Optional[int] = None
        if build_year is not None:
            age_years = max(0, CURRENT_YEAR - build_year)

        # ㎡単価（修繕積立金のみ。管理品質補正用）
        repair_yen_per_sqm: Optional[float] = None
        if area_sqm and area_sqm > 0 and repair_reserve_fund is not None:
            repair_yen_per_sqm = repair_reserve_fund / area_sqm
        # （管理費+修繕）/㎡：較正対象の特徴量
        mgmt_repair_per_sqm: Optional[float] = None
        if area_sqm and area_sqm > 0:
            mgmt = (management_fee or 0) + (repair_reserve_fund or 0)
            if mgmt > 0:
                mgmt_repair_per_sqm = mgmt / area_sqm

        # 区名から係数取得（address → ward_name → ward_coefficients）。5賃料成長グループ・在庫スコア・高さ制限フラグ。
        area_rank = "Tier3"
        trend_coefficient = 1.0
        rent_cagr = 0.035
        rent_cluster_group = 5
        inventory_trend_score = 1.0
        tower_regulation_flag = 0
        tower_potential_flag = 0
        market_momentum_score = 1.0
        ward_name = _ward_from_address(address)
        if ward_name and self._ward_coefficients is not None:
            match = self._ward_coefficients[
                self._ward_coefficients["ward_name"].astype(str).str.strip() == ward_name.strip()
            ]
            if not match.empty:
                row = match.iloc[0]
                rent_cagr = float(row.get("rent_cagr", 0.035))
                # 新CSV: rent_cluster_group から area_rank を導出（1,2→Tier1, 3→Tier2, 4,5→Tier3）
                if "rent_cluster_group" in self._ward_coefficients.columns:
                    rent_cluster_group = int(row.get("rent_cluster_group", 5))
                    if rent_cluster_group <= 2:
                        area_rank = "Tier1"
                    elif rent_cluster_group == 3:
                        area_rank = "Tier2"
                    else:
                        area_rank = "Tier3"
                else:
                    area_rank = str(row.get("area_rank", "Tier3"))
                inventory_trend_score = float(row.get("inventory_trend_score", row.get("market_momentum_score", 1.0)))
                market_momentum_score = inventory_trend_score
                tower_regulation_flag = int(row.get("tower_regulation_flag", row.get("tower_potential_flag", 0)))
                tower_potential_flag = (1 - tower_regulation_flag) if "tower_regulation_flag" in self._ward_coefficients.columns else int(row.get("tower_potential_flag", 0))
                trend_coefficient = 1.0

        # 築年数に応じた適正修繕積立金/㎡
        guideline_yen_per_sqm: Optional[float] = None
        if age_years is not None and self._management_guidelines is not None:
            for _, row in self._management_guidelines.iterrows():
                if row["age_min"] <= age_years <= row["age_max"]:
                    guideline_yen_per_sqm = float(row["guideline_yen_per_sqm"])
                    break

        # 推定賃料が未入力の場合は簡易利回り（都心3.5%/準都心4%/郊外4.5%）で逆算
        if estimated_rent is None and listing_price and listing_price > 0:
            cap = CAP_RATE_TIER3
            if area_rank == "Tier1":
                cap = CAP_RATE_TIER1
            elif area_rank == "Tier2":
                cap = CAP_RATE_TIER2
            estimated_rent = listing_price * cap / 12

        return {
            "listing_price": listing_price,
            "station_name": station_name,
            "address": address,
            "ward_name": ward_name,
            "area_rank": area_rank,
            "rent_cluster_group": rent_cluster_group,
            "trend_coefficient": trend_coefficient,
            "rent_cagr": rent_cagr,
            "inventory_trend_score": inventory_trend_score,
            "tower_regulation_flag": tower_regulation_flag,
            "tower_potential_flag": tower_potential_flag,
            "market_momentum_score": market_momentum_score,
            "walk_min": walk_min,
            "area_sqm": area_sqm,
            "build_year": build_year,
            "age_years": age_years,
            "repair_reserve_fund": repair_reserve_fund,
            "repair_yen_per_sqm": repair_yen_per_sqm,
            "mgmt_repair_per_sqm": mgmt_repair_per_sqm,
            "guideline_yen_per_sqm": guideline_yen_per_sqm,
            "management_fee": management_fee,
            "total_units": total_units,
            "floor": floor,
            "estimated_rent": estimated_rent,
            "hazard_risk": hazard_risk,
        }

    def predict(self, property_data: dict[str, Any]) -> dict[str, Any]:
        """
        辞書データを受け取り、現在の推定成約価格と10年後の3シナリオ予測を返す。

        2026年経済予測に基づく FutureEstatePredictor（収益還元・原価法ハイブリッド）を使用。
        返り値:
          - current_estimated_contract_price: 現在の推定成約価格（円）
          - 10y_forecast: { standard, best, worst } ← neutral, optimistic, pessimistic に相当
          - risk_factors / positive_factors: 新アルゴリズムから導出
        """
        self._ensure_loaded()
        features = self.preprocess(property_data)
        listing_price = features.get("listing_price") or 0.0
        if listing_price <= 0:
            return {
                "current_estimated_contract_price": 0,
                "10y_forecast": {"standard": 0, "best": 0, "worst": 0},
                "rent_yield_floor": None,
                "implied_gain_yen": None,
                "implied_gain_ratio": None,
                "profit_level": "低",
                "risk_factors": ["価格情報なし"],
                "positive_factors": [],
            }

        # FutureEstatePredictor 用の入力（listing_price は円、address/ward/build_year/total_units 等）
        prop = {**property_data}
        prop["listing_price"] = listing_price
        prop["address"] = features.get("address")
        prop["ward"] = features.get("ward_name")
        prop["build_year"] = features.get("build_year")
        prop["total_units"] = features.get("total_units")
        prop["walk_min"] = features.get("walk_min")
        if features.get("estimated_rent") is not None:
            prop["current_rent"] = features.get("estimated_rent")

        from future_estate_predictor import FutureEstatePredictor

        future = FutureEstatePredictor()
        result = future.predict(prop)

        contract_price = result["current_valuation"]
        f2035 = result["forecast_2035"]
        forecast_10y = {
            "standard": f2035["neutral"]["price"],
            "best": f2035["optimistic"]["price"],
            "worst": f2035["pessimistic"]["price"],
        }
        implied_gain_yen = result.get("implied_gain_yen", 0)
        implied_gain_ratio = result.get("implied_gain_ratio", 0.0)
        grade = result.get("investment_grade", "C")
        if grade in ("S", "A"):
            profit_level: Literal["高", "中", "低"] = "高"
        elif grade == "B":
            profit_level = "中"
        else:
            profit_level = "低"

        risk_factors: list[str] = []
        positive_factors: list[str] = []
        if grade == "C":
            risk_factors.append("金利・賃料悪化シナリオで残債割れリスク")
        elif grade in ("S", "A"):
            positive_factors.append("賃料・建築費シナリオで下値支持")
        if result.get("strategic_advice"):
            positive_factors.append(result["strategic_advice"])

        # 悲観シナリオ価格を Yield Floor の代わりに利用（レポート互換）
        rent_yield_floor_val = f2035["pessimistic"]["price"] if f2035["pessimistic"]["price"] else None

        return {
            "current_estimated_contract_price": contract_price,
            "10y_forecast": forecast_10y,
            "rent_yield_floor": rent_yield_floor_val,
            "implied_gain_yen": implied_gain_yen,
            "implied_gain_ratio": implied_gain_ratio,
            "profit_level": profit_level,
            "risk_factors": risk_factors,
            "positive_factors": positive_factors,
        }


def listing_to_property_data(listing: dict[str, Any]) -> dict[str, Any]:
    """
    SUUMO/HOMES スクレイピング結果の辞書を predict() 用の property_data に変換する。
    price_man(万円) → listing_price(円)、station_line → station_name 抽出、area_m2 / built_year 等をそのまま渡す。
    repair_reserve_fund / management_fee が無い場合は省略（管理品質補正はスキップ）。
    """
    out: dict[str, Any] = {}
    if "price_man" in listing and listing["price_man"] is not None:
        out["listing_price"] = int(listing["price_man"]) * 10000
    if "station_line" in listing and listing["station_line"]:
        out["station_line"] = listing["station_line"]
    if "station_name" in listing and listing["station_name"]:
        out["station_name"] = listing["station_name"]
    for key in ("walk_min", "area_m2", "area_sqm", "built_year", "build_year", "total_units", "floor_position", "floor"):
        if key in listing and listing[key] is not None:
            out[key] = listing[key]
    if "area_m2" in listing and "area_sqm" not in out:
        out["area_sqm"] = listing["area_m2"]
    if "built_year" in listing and "build_year" not in out:
        out["build_year"] = listing["built_year"]
    if "floor_position" in listing and "floor" not in out:
        out["floor"] = listing["floor_position"]
    if "repair_reserve_fund" in listing:
        out["repair_reserve_fund"] = listing["repair_reserve_fund"]
    if "management_fee" in listing:
        out["management_fee"] = listing["management_fee"]
    for key in ("notes", "features", "description", "remarks", "備考", "特徴"):
        if key in listing and listing[key] is not None:
            out[key] = listing[key]
    if "estimated_rent" in listing and listing["estimated_rent"] is not None:
        out["estimated_rent"] = listing["estimated_rent"]
    if "hazard_risk" in listing and listing["hazard_risk"] is not None:
        out["hazard_risk"] = listing["hazard_risk"]
    for key in ("address", "住所", "addr"):
        if key in listing and listing[key] is not None:
            out["address"] = listing[key]
            break
    return out


if __name__ == "__main__":
    predictor = MansionPricePredictor()
    predictor.load_data()
    # 要件のサンプル入力（円・住所で区判定・㎡）
    sample = {
        "listing_price": 85_000_000,
        "address": "東京都江東区豊洲3-2-1",
        "station_name": "豊洲",
        "walk_min": 5,
        "area_sqm": 70.5,
        "build_year": 2018,
        "repair_reserve_fund": 12000,
        "management_fee": 15000,
        "total_units": 400,
        "floor": 20,
    }
    result = predictor.predict(sample)
    print("current_estimated_contract_price:", result["current_estimated_contract_price"])
    print("10y_forecast:", result["10y_forecast"])
    print("rent_yield_floor:", result.get("rent_yield_floor"))
    print("risk_factors:", result["risk_factors"])
    print("positive_factors:", result.get("positive_factors"))
