"""spec exclusion ロジックのテスト.

scraper_common.get_effective_area_min_m2 と、
apply_spec_exclusions SQL関数の判定条件に対応するPythonロジックを検証する。
"""

from __future__ import annotations

from typing import Optional

import pytest

from scraper_common import (
    TOSHIN_3_WARDS,
    WATERFRONT_ADDRESS_KEYWORDS,
    get_effective_area_min_m2,
)


# ────────────────── get_effective_area_min_m2 ──────────────────


class TestGetEffectiveAreaMinM2:
    def test_toshin_ward_minato(self):
        assert get_effective_area_min_m2("東京都港区南青山1丁目") == 55

    def test_toshin_ward_chuo(self):
        assert get_effective_area_min_m2("東京都中央区築地1丁目") == 55

    def test_toshin_ward_chiyoda(self):
        assert get_effective_area_min_m2("東京都千代田区番町1丁目") == 55

    def test_waterfront_toyosu(self):
        assert get_effective_area_min_m2("東京都江東区豊洲3丁目") == 55

    def test_waterfront_kachidoki(self):
        assert get_effective_area_min_m2("東京都中央区勝どき5丁目") == 55

    def test_waterfront_harumi(self):
        assert get_effective_area_min_m2("東京都中央区晴海2丁目") == 55

    def test_waterfront_ariake(self):
        assert get_effective_area_min_m2("東京都江東区有明1丁目") == 55

    def test_waterfront_shinonome(self):
        assert get_effective_area_min_m2("東京都江東区東雲1丁目") == 55

    def test_non_toshin_uses_default(self):
        result = get_effective_area_min_m2("東京都墨田区錦糸1丁目")
        assert result == 60

    def test_empty_address_uses_default(self):
        assert get_effective_area_min_m2("") == 60

    def test_boundary_area_55_toshin(self):
        assert get_effective_area_min_m2("東京都港区芝1丁目") == 55


# ────────────────── spec exclusion 判定ロジック（Python版） ──────────────────


def compute_spec_exclusion_reasons(
    *,
    price_man: Optional[int],
    area_m2: Optional[float],
    address: str,
    price_max_man: int = 12000,
    price_min_man: int = 7500,
    area_min_m2: int = 60,
    area_min_toshin_m2: int = 55,
) -> list[str]:
    """SQL の apply_spec_exclusions と同等のPython判定."""
    reasons: list[str] = []

    if price_man is not None and price_man > price_max_man:
        reasons.append(f"price_over_{price_max_man}")
    if price_man is not None and price_man < price_min_man:
        reasons.append(f"price_under_{price_min_man}")
    if area_m2 is not None and area_m2 < area_min_toshin_m2:
        reasons.append(f"area_under_{area_min_toshin_m2}")

    is_toshin = any(ward in address for ward in TOSHIN_3_WARDS)
    is_waterfront = any(kw in address for kw in WATERFRONT_ADDRESS_KEYWORDS)

    if (
        area_m2 is not None
        and area_m2 >= area_min_toshin_m2
        and area_m2 < area_min_m2
        and not is_toshin
        and not is_waterfront
    ):
        reasons.append(f"area_under_{area_min_m2}_non_toshin")

    return reasons


class TestSpecExclusionReasons:
    def test_in_spec_typical(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=65.0, address="東京都江東区東陽1丁目"
        )
        assert reasons == []

    def test_price_over_limit(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=13000, area_m2=70.0, address="東京都江東区東陽1丁目"
        )
        assert reasons == ["price_over_12000"]

    def test_price_under_limit(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=6000, area_m2=70.0, address="東京都江東区東陽1丁目"
        )
        assert reasons == ["price_under_7500"]

    def test_area_under_55_anywhere(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=50.0, address="東京都港区南青山1丁目"
        )
        assert "area_under_55" in reasons

    def test_area_55_59_non_toshin_excluded(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=58.0, address="東京都墨田区錦糸1丁目"
        )
        assert "area_under_60_non_toshin" in reasons

    def test_area_55_59_toshin_allowed(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=58.0, address="東京都港区南青山1丁目"
        )
        assert reasons == []

    def test_area_55_59_waterfront_allowed(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=57.0, address="東京都江東区豊洲3丁目"
        )
        assert reasons == []

    def test_null_price_not_excluded(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=None, area_m2=65.0, address="東京都江東区東陽1丁目"
        )
        assert reasons == []

    def test_null_area_not_excluded(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=None, address="東京都江東区東陽1丁目"
        )
        assert reasons == []

    def test_multiple_reasons(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=15000, area_m2=50.0, address="東京都墨田区錦糸1丁目"
        )
        assert "price_over_12000" in reasons
        assert "area_under_55" in reasons

    def test_boundary_price_at_limit(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=12000, area_m2=65.0, address="東京都江東区東陽1丁目"
        )
        assert reasons == []

    def test_boundary_price_just_over(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=12001, area_m2=65.0, address="東京都江東区東陽1丁目"
        )
        assert reasons == ["price_over_12000"]

    def test_boundary_area_at_60_non_toshin(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=60.0, address="東京都墨田区錦糸1丁目"
        )
        assert reasons == []

    def test_boundary_area_just_under_60_non_toshin(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=59.9, address="東京都墨田区錦糸1丁目"
        )
        assert "area_under_60_non_toshin" in reasons

    def test_tsukishima_waterfront(self):
        reasons = compute_spec_exclusion_reasons(
            price_man=10000, area_m2=56.0, address="東京都中央区月島1丁目"
        )
        assert reasons == []
