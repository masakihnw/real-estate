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


class TestDeleteDuplicateListing:
    """_delete_duplicate_listing のテスト。

    子テーブル（listing_sources / enrichments / price_history / listing_events）は
    すべて ON DELETE CASCADE（migration 001）なので、listings への単一 DELETE で
    原子的に削除されることを検証する。旧実装は5つの DELETE を非トランザクションで
    逐次実行しており、途中失敗で孤児レコードが残る温床だった。
    """

    def test_single_cascade_delete_on_listings_only(self):
        from unittest.mock import MagicMock
        from supabase_sync import _delete_duplicate_listing

        client = MagicMock()
        _delete_duplicate_listing(client, 123)

        # listings テーブルのみに対する1回の delete であること
        tables_called = [c.args[0] for c in client.table.call_args_list]
        assert tables_called == ["listings"]
        client.table.return_value.delete.return_value.eq.assert_called_once_with("id", 123)

    def test_delete_failure_propagates(self):
        """削除失敗は握り潰さず例外を伝播させる（部分削除が無いので安全に再試行可能）。"""
        from unittest.mock import MagicMock
        import pytest as _pytest
        from supabase_sync import _delete_duplicate_listing

        client = MagicMock()
        client.table.return_value.delete.return_value.eq.return_value.execute.side_effect = \
            Exception("network error")
        with _pytest.raises(Exception, match="network error"):
            _delete_duplicate_listing(client, 123)
