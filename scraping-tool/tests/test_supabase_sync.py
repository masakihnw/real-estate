"""Tests for supabase_sync._sanitize_value."""

from __future__ import annotations

import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from supabase_sync import _sanitize_value


class TestSanitizeValue:
    def test_nan_replaced_with_none(self):
        assert _sanitize_value(float("nan")) is None

    def test_infinity_replaced_with_none(self):
        assert _sanitize_value(float("inf")) is None
        assert _sanitize_value(float("-inf")) is None

    def test_normal_float_unchanged(self):
        assert _sanitize_value(3.14) == 3.14

    def test_zero_float_unchanged(self):
        assert _sanitize_value(0.0) == 0.0

    def test_null_byte_stripped(self):
        assert _sanitize_value("hello\x00world") == "helloworld"

    def test_clean_string_unchanged(self):
        assert _sanitize_value("hello") == "hello"

    def test_dict_recursion(self):
        result = _sanitize_value({"a": float("nan"), "b": "ok\x00"})
        assert result == {"a": None, "b": "ok"}

    def test_list_recursion(self):
        result = _sanitize_value([float("inf"), "test\x00"])
        assert result == [None, "test"]

    def test_nested_dict_in_list(self):
        result = _sanitize_value([{"x": float("nan"), "y": [float("-inf")]}])
        assert result == [{"x": None, "y": [None]}]

    def test_none_passthrough(self):
        assert _sanitize_value(None) is None

    def test_int_passthrough(self):
        assert _sanitize_value(42) == 42

    def test_bool_passthrough(self):
        assert _sanitize_value(True) is True
        assert _sanitize_value(False) is False

    def test_empty_dict(self):
        assert _sanitize_value({}) == {}

    def test_empty_list(self):
        assert _sanitize_value([]) == []

    def test_realistic_enrichment_row(self):
        row = {
            "listing_id": 123,
            "ss_profit_pct": float("nan"),
            "reinfolib_market_data": '{"price_ratio": 1.05}',
            "ss_radar_data": None,
            "latitude": 35.6762,
        }
        result = _sanitize_value(row)
        assert result["listing_id"] == 123
        assert result["ss_profit_pct"] is None
        assert result["reinfolib_market_data"] == '{"price_ratio": 1.05}'
        assert result["ss_radar_data"] is None
        assert result["latitude"] == 35.6762
