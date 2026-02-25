"""build_supply_trends.py のユニットテスト"""
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))

import pytest

from build_supply_trends import aggregate_trends, build_supply_trends


class TestBuildSupplyTrends:
    def test_trend_aggregation(self):
        """トレンドデータの集計が正しいこと"""
        listings = [
            {
                "name": "A",
                "address": "東京都渋谷区道玄坂1-1",
                "added_at": "2025-01-15",
            },
            {
                "name": "B",
                "address": "東京都渋谷区神南1-1",
                "added_at": "2025-01-20",
            },
            {
                "name": "C",
                "address": "東京都港区赤坂1-1",
                "added_at": "2025-02-01",
            },
        ]
        result = aggregate_trends(listings)
        assert result["total_count"] == 3
        assert "by_ward" in result
        assert "渋谷区" in result["by_ward"]
        assert "港区" in result["by_ward"]
        assert result["by_ward"]["渋谷区"]["count"] == 2
        assert result["by_ward"]["港区"]["count"] == 1
        assert "quarters" in result
        assert len(result["quarters"]) >= 1

    def test_empty_input(self):
        """空の入力でもエラーにならないこと"""
        result = aggregate_trends([])
        assert result["total_count"] == 0
        assert result["by_ward"] == {}
        assert result["quarters"] == []

    def test_build_supply_trends_empty(self):
        """build_supply_trends も空入力でエラーにならない"""
        result = build_supply_trends([])
        assert result["total_count"] == 0

    def test_build_supply_trends_none(self):
        """None を渡してもエラーにならない"""
        result = build_supply_trends(None)
        assert result["total_count"] == 0
