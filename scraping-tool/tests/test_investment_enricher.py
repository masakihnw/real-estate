"""investment_enricher.py のユニットテスト"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import pytest
from datetime import datetime

from investment_enricher import (
    calculate_investment_score,
    calculate_days_on_market,
    count_competing_listings,
    inject_price_history,
    enrich_investment_metadata,
)


class TestInvestmentEnricher:
    """investment_enricher のテスト"""

    def test_score_calculation(self):
        """投資スコアの計算が正しいこと（0-100の範囲、データ不足時は0）"""
        # 最小限のデータでは 0 または predictor が動けばスコアが返る
        listing = {
            "name": "テストマンション",
            "price_man": 9000,
            "area_m2": 70,
            "address": "東京都渋谷区道玄坂1-1",
            "built_year": 2015,
            "station_line": "JR山手線 渋谷駅",
            "walk_min": 5,
        }
        score = calculate_investment_score(listing)
        assert isinstance(score, (int, float))
        assert 0 <= score <= 100

    def test_score_empty_listing_returns_zero(self):
        """空の物件データではスコア0"""
        assert calculate_investment_score({}) == 0.0

    def test_days_on_market(self):
        """掲載日数の計算が正しいこと"""
        ref = datetime(2025, 2, 25)
        listing = {"added_at": "2025-02-20T00:00:00Z"}
        days = calculate_days_on_market(listing, reference_date=ref)
        assert days == 5

    def test_days_on_market_date_only(self):
        """日付のみ（YYYY-MM-DD）でも計算可能"""
        ref = datetime(2025, 2, 25)
        listing = {"added_at": "2025-02-15"}
        days = calculate_days_on_market(listing, reference_date=ref)
        assert days == 10

    def test_days_on_market_no_data_returns_none(self):
        """added_at がない場合は None"""
        assert calculate_days_on_market({}) is None
        assert calculate_days_on_market({"name": "A"}) is None

    def test_competing_listings(self):
        """競合物件数のカウントが正しいこと"""
        base = {
            "name": "パークタワー渋谷",
            "address": "東京都渋谷区道玄坂1-1",
        }
        other_same = {
            "name": "パークタワー渋谷",
            "address": "東京都渋谷区道玄坂1-2",
        }
        other_diff = {
            "name": "別マンション",
            "address": "東京都港区赤坂1-1",
        }
        all_listings = [base, other_same, other_diff]
        count = count_competing_listings(base, all_listings)
        assert count == 2  # base + other_same（同一区・正規化後同名）

    def test_competing_listings_single(self):
        """1件のみの場合は1"""
        listing = {"name": "A", "address": "東京都渋谷区"}
        assert count_competing_listings(listing, [listing]) == 1

    def test_price_history_injection(self):
        """価格履歴の注入が正しいこと"""
        listing = {"name": "A", "price_man": 8000}
        history = [
            {"date": "2025-01-01", "price_man": 8500},
            {"date": "2025-02-01", "price_man": 8000},
        ]
        result = inject_price_history(listing, history)
        assert "price_history" in result
        assert len(result["price_history"]) == 2
        assert result["price_history"][0]["price_man"] == 8500
        assert result["price_history"][1]["date"] == "2025-02-01"

    def test_price_history_empty(self):
        """空の履歴では price_history を付与しない"""
        listing = {"name": "A"}
        result = inject_price_history(listing, [])
        assert "price_history" not in result

    def test_enrich_investment_metadata(self):
        """enrich_investment_metadata が全フィールドを付与すること"""
        listing = {
            "name": "テスト",
            "price_man": 9000,
            "address": "東京都渋谷区",
            "added_at": "2025-02-20",
        }
        all_listings = [listing]
        ref = datetime(2025, 2, 25)
        result = enrich_investment_metadata(listing, all_listings, ref)
        assert "investment_score" in result
        assert "days_on_market" in result
        assert result["days_on_market"] == 5
        assert "competing_listings" in result
        assert result["competing_listings"] == 1
