#!/usr/bin/env python3
"""
オプショナル依存（asset_score, loan_calc, commute, price_predictor 等）を一箇所でロードする。
ImportError 時は "-" / None 等の互換値を返すスタブに差し替え。generate_report / slack_notify から try/except を撤去する。
"""
from typing import Any, Optional

from report_utils import format_price

# シングルトン。呼び出し側は "from optional_features import optional_features" で利用する。
optional_features: "OptionalFeatures"


class OptionalFeatures:
    """オプショナル機能のラッパー。未インストール時はスタブで互換値を返す。"""

    def get_asset_score_and_rank(self, r: dict, **kwargs: Any) -> tuple[float, str]:
        return 0.0, "-"

    def get_asset_score_and_rank_with_breakdown(self, r: dict, **kwargs: Any) -> tuple[float, str, str]:
        return 0.0, "-", "-"

    def simulate_10year_from_listing(self, r: dict) -> Any:
        return None

    def format_simulation_for_report(self, sim: Any) -> tuple[str, str, str, str]:
        return "-", "-", "-", "-"

    def get_loan_display_for_listing(self, price_man: Optional[float]) -> tuple[str, str]:
        return "-", "-"

    def get_commute_display_with_estimate(self, station_line: str, walk_min: Optional[int]) -> tuple[str, str]:
        return "-", "-"

    def get_commute_total_minutes(self, station_line: str, walk_min: Optional[int]) -> tuple[Optional[int], Optional[int]]:
        return (None, None)

    def get_destination_labels(self) -> tuple[str, str]:
        return "エムスリーキャリア", "playground(一番町)"

    def format_all_station_walk(self, station_line: str, fallback_walk_min: Optional[int]) -> str:
        return format_walk_stub(fallback_walk_min)

    def get_three_scenario_columns(self, listing: dict[str, Any]) -> tuple[str, str, str]:
        return "-", "-", "-"

    def get_price_predictor_3scenarios(self, listing: dict[str, Any]) -> str:
        return "-"


def format_walk_stub(walk_min: Optional[int]) -> str:
    if walk_min is None:
        return "-"
    return f"徒歩{walk_min}分"


def _load_optional_features() -> OptionalFeatures:
    f = OptionalFeatures()

    try:
        from asset_score import get_asset_score_and_rank, get_asset_score_and_rank_with_breakdown
        f.get_asset_score_and_rank = get_asset_score_and_rank
        f.get_asset_score_and_rank_with_breakdown = get_asset_score_and_rank_with_breakdown
    except ImportError:
        pass

    try:
        from asset_simulation import simulate_10year_from_listing, format_simulation_for_report
        f.simulate_10year_from_listing = simulate_10year_from_listing
        f.format_simulation_for_report = format_simulation_for_report
    except ImportError:
        pass

    try:
        from loan_calc import get_loan_display_for_listing
        f.get_loan_display_for_listing = get_loan_display_for_listing
    except ImportError:
        pass

    try:
        from commute import (
            get_commute_display_with_estimate,
            get_commute_total_minutes,
            get_destination_labels,
            format_all_station_walk,
        )
        f.get_commute_display_with_estimate = get_commute_display_with_estimate
        f.get_commute_total_minutes = get_commute_total_minutes
        f.get_destination_labels = get_destination_labels
        f.format_all_station_walk = format_all_station_walk
    except ImportError:
        pass

    try:
        from price_predictor import (
            MansionPricePredictor,
            listing_to_property_data,
            _calc_loan_residual_10y_yen,
        )
        _predictor: Optional[MansionPricePredictor] = None

        def _get_predictor() -> MansionPricePredictor:
            nonlocal _predictor
            if _predictor is None:
                _predictor = MansionPricePredictor()
                _predictor.load_data()
            return _predictor

        def _format_scenario_cell(price_yen: int, contract_yen: int, loan_residual_yen: float) -> str:
            if price_yen <= 0 or contract_yen <= 0:
                return "-"
            price_man = price_yen / 10000
            implied_yen = price_yen - loan_residual_yen
            implied_man = implied_yen / 10000
            change_pct = (price_yen / contract_yen - 1.0) * 100
            price_str = format_price(int(round(price_man)))
            if abs(implied_man) >= 10000:
                oku = int(abs(implied_man) // 10000)
                man = int(round(abs(implied_man) % 10000))
                sign = "+" if implied_man >= 0 else "-"
                implied_str = f"{sign}{oku}億{man}万円" if man else f"{sign}{oku}億円"
            else:
                implied_str = f"{'+' if implied_man >= 0 else ''}{int(round(implied_man))}万円"
            return f"{price_str}（{implied_str}/{change_pct:+.1f}%）"

        def get_three_scenario_columns(listing: dict[str, Any]) -> tuple[str, str, str]:
            if not listing.get("price_man") and not listing.get("listing_price"):
                return "-", "-", "-"
            prop = listing_to_property_data(listing)
            if not prop.get("listing_price"):
                return "-", "-", "-"
            try:
                pred = _get_predictor().predict(prop)
                contract = pred.get("current_estimated_contract_price") or 0
                forecast = pred.get("10y_forecast") or {}
                best_yen = forecast.get("best") or 0
                std_yen = forecast.get("standard") or 0
                worst_yen = forecast.get("worst") or 0
                if contract <= 0:
                    return "-", "-", "-"
                loan_residual = _calc_loan_residual_10y_yen(contract)
                opt = _format_scenario_cell(best_yen, contract, loan_residual)
                neu = _format_scenario_cell(std_yen, contract, loan_residual)
                pes = _format_scenario_cell(worst_yen, contract, loan_residual)
                return opt, neu, pes
            except Exception:
                return "-", "-", "-"

        def get_price_predictor_3scenarios(listing: dict[str, Any]) -> str:
            opt, neu, pes = get_three_scenario_columns(listing)
            if opt == "-" and neu == "-" and pes == "-":
                return "-"
            return f"{neu} / {opt} / {pes}"

        f.get_three_scenario_columns = get_three_scenario_columns
        f.get_price_predictor_3scenarios = get_price_predictor_3scenarios
    except ImportError:
        pass

    return f


optional_features = _load_optional_features()
