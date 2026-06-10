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


class TestPlanSourceSync:
    """_plan_source_sync（同期計画の純粋関数）のテスト。

    旧実装は物件1件ごとに upsert + SELECT + insert を逐次実行しており、
    800件で最大 3,200 HTTP コールが発生していた。計画フェーズ（純粋関数）と
    実行フェーズ（バッチ I/O）に分離する。
    """

    def _item(self, name="マンションA", price=5000, url="https://example.com/1"):
        return {
            "name": name,
            "price_man": price,
            "url": url,
            "address": "東京都江東区1-1",
            "layout": "3LDK",
            "area_m2": 70.0,
            "built_year": 2015,
        }

    def test_new_listing_creates_appeared_event_and_price_history(self):
        from supabase_sync import _plan_source_sync

        plan = _plan_source_sync(
            items=[(self._item(), "ik1", 101)],
            existing_listings={},          # ik1 は新規
            existing_sources={},
            source="suumo",
        )
        assert plan.summary["new"] == 1
        assert len(plan.source_rows) == 1
        assert plan.source_rows[0]["listing_id"] == 101
        assert [e["event_type"] for e in plan.event_rows] == ["appeared"]
        assert len(plan.price_history_rows) == 1
        assert plan.price_history_rows[0]["price_man"] == 5000

    def test_price_change_creates_price_changed_event(self):
        from supabase_sync import _plan_source_sync

        plan = _plan_source_sync(
            items=[(self._item(price=4800), "ik1", 101)],
            existing_listings={"ik1": 101},
            existing_sources={101: {"id": 9, "is_active": True, "price_man": 5000,
                                    "consecutive_misses": 0}},
            source="suumo",
        )
        assert plan.summary["updated"] == 1
        assert [e["event_type"] for e in plan.event_rows] == ["price_changed"]
        assert plan.event_rows[0]["old_value"] == "5000"
        assert plan.event_rows[0]["new_value"] == "4800"
        assert len(plan.price_history_rows) == 1

    def test_unchanged_listing(self):
        from supabase_sync import _plan_source_sync

        plan = _plan_source_sync(
            items=[(self._item(price=5000), "ik1", 101)],
            existing_listings={"ik1": 101},
            existing_sources={101: {"id": 9, "is_active": True, "price_man": 5000,
                                    "consecutive_misses": 0}},
            source="suumo",
        )
        assert plan.summary["unchanged"] == 1
        assert plan.event_rows == []
        assert plan.price_history_rows == []

    def test_reappeared_listing(self):
        from supabase_sync import _plan_source_sync

        plan = _plan_source_sync(
            items=[(self._item(), "ik1", 101)],
            existing_listings={},          # active には存在しない
            existing_sources={101: {"id": 9, "is_active": False, "price_man": 5000,
                                    "consecutive_misses": 0}},
            source="suumo",
        )
        assert plan.summary["reappeared"] == 1
        assert [e["event_type"] for e in plan.event_rows] == ["reappeared"]

    def test_duplicate_identity_keys_deduped_for_batch_upsert(self):
        """同一バッチ内の同一 (listing_id, source) は1行に統合される。

        PostgREST のバッチ upsert は同一キーが2回出現するとエラーになるため。
        """
        from supabase_sync import _plan_source_sync

        plan = _plan_source_sync(
            items=[
                (self._item(price=5000, url="https://example.com/a"), "ik1", 101),
                (self._item(price=5100, url="https://example.com/b"), "ik1", 101),
            ],
            existing_listings={"ik1": 101},
            existing_sources={101: {"id": 9, "is_active": True, "price_man": 5000,
                                    "consecutive_misses": 0}},
            source="suumo",
        )
        assert len(plan.source_rows) == 1, "バッチupsertは同一キー重複でエラーになる"


class TestPlanGracePeriod:
    """_plan_grace_period（掲載終了判定の純粋関数）のテスト。"""

    def test_below_threshold_increments_misses(self):
        from supabase_sync import _plan_grace_period

        plan = _plan_grace_period(
            existing_listings={"ik1": 101},
            seen_identity_keys=set(),
            existing_sources={101: {"id": 9, "is_active": True, "consecutive_misses": 0}},
            grace_threshold=2,
            source="suumo",
        )
        assert plan.deactivate_source_ids == []
        assert plan.miss_increment_groups == {1: [9]}
        assert plan.removed_count == 0

    def test_reaching_threshold_deactivates(self):
        from supabase_sync import _plan_grace_period

        plan = _plan_grace_period(
            existing_listings={"ik1": 101},
            seen_identity_keys=set(),
            existing_sources={101: {"id": 9, "is_active": True, "consecutive_misses": 1}},
            grace_threshold=2,
            source="suumo",
        )
        assert plan.deactivate_source_ids == [9]
        assert plan.deactivate_listing_candidates == [101]
        assert [e["event_type"] for e in plan.event_rows] == ["removed"]
        assert plan.removed_count == 1

    def test_seen_listing_not_touched(self):
        from supabase_sync import _plan_grace_period

        plan = _plan_grace_period(
            existing_listings={"ik1": 101},
            seen_identity_keys={"ik1"},
            existing_sources={101: {"id": 9, "is_active": True, "consecutive_misses": 1}},
            grace_threshold=2,
            source="suumo",
        )
        assert plan.deactivate_source_ids == []
        assert plan.miss_increment_groups == {}
        assert plan.removed_count == 0

    def test_inactive_source_skipped(self):
        from supabase_sync import _plan_grace_period

        plan = _plan_grace_period(
            existing_listings={"ik1": 101},
            seen_identity_keys=set(),
            existing_sources={101: {"id": 9, "is_active": False, "consecutive_misses": 0}},
            grace_threshold=2,
            source="suumo",
        )
        assert plan.deactivate_source_ids == []
        assert plan.miss_increment_groups == {}


class TestSyncSourceListingsIntegration:
    """_sync_source_listings のバッチ実行オーケストレーション統合テスト。

    N 件の物件に対して 2N+ リクエストではなく、テーブルごとの
    バッチリクエストになっていることをモックで検証する。
    """

    def _make_item(self, name: str, price: int, url: str) -> dict:
        return {
            "name": name,
            "price_man": price,
            "url": url,
            "address": "東京都江東区豊洲1-1",
            "layout": "3LDK",
            "area_m2": 70.0,
            "built_year": 2015,
            "floor_position": 5,
        }

    def _make_client(self, existing_listing_rows, existing_source_rows):
        from unittest.mock import MagicMock

        client = MagicMock()
        tables: dict[str, MagicMock] = {}
        upsert_batches: dict[str, list] = {"listings": [], "listing_sources": []}
        insert_batches: dict[str, list] = {"price_history": [], "listing_events": []}
        next_id = [100]

        def table_router(name):
            if name in tables:
                return tables[name]
            tbl = MagicMock()
            tables[name] = tbl

            if name == "listings":
                # ページネーション select（1回で終了）
                (tbl.select.return_value.eq.return_value.range.return_value
                 .execute.return_value) = MagicMock(data=existing_listing_rows)

                def upsert_side(batch, **kw):
                    rows = batch if isinstance(batch, list) else [batch]
                    upsert_batches["listings"].append(rows)
                    data = []
                    for r in rows:
                        data.append({"identity_key": r["identity_key"], "id": next_id[0]})
                        next_id[0] += 1
                    m = MagicMock()
                    m.execute.return_value = MagicMock(data=data)
                    return m
                tbl.upsert.side_effect = upsert_side
            elif name == "listing_sources":
                # 既存ソース取得: select().eq(source).in_(listing_id)
                (tbl.select.return_value.eq.return_value.in_.return_value
                 .execute.return_value) = MagicMock(data=existing_source_rows)
                # grace period の active 残存チェック: select().in_().eq()
                (tbl.select.return_value.in_.return_value.eq.return_value
                 .execute.return_value) = MagicMock(data=[])

                def upsert_side(batch, **kw):
                    rows = batch if isinstance(batch, list) else [batch]
                    upsert_batches["listing_sources"].append(rows)
                    m = MagicMock()
                    m.execute.return_value = MagicMock(data=[])
                    return m
                tbl.upsert.side_effect = upsert_side
            elif name in ("price_history", "listing_events"):
                def insert_side(batch, _name=name, **kw):
                    rows = batch if isinstance(batch, list) else [batch]
                    insert_batches[_name].append(rows)
                    m = MagicMock()
                    m.execute.return_value = MagicMock(data=[])
                    return m
                tbl.insert.side_effect = insert_side
            return tbl

        client.table.side_effect = table_router
        return client, upsert_batches, insert_batches

    def test_new_listings_batched(self):
        """新規2件: listings/listing_sources は各1バッチ、イベント・価格履歴もバッチ。"""
        from supabase_sync import _sync_source_listings

        client, upserts, inserts = self._make_client(
            existing_listing_rows=[], existing_source_rows=[])

        items = [
            self._make_item("マンションA", 5000, "https://example.com/a"),
            self._make_item("マンションB", 8000, "https://example.com/b"),
        ]
        summary = _sync_source_listings(client, items, "suumo", "chuko")

        assert summary["new"] == 2
        assert summary["removed"] == 0
        # listings upsert は1バッチ（2行）
        assert len(upserts["listings"]) == 1
        assert len(upserts["listings"][0]) == 2
        # listing_sources upsert は1バッチ（2行）
        assert len(upserts["listing_sources"]) == 1
        assert len(upserts["listing_sources"][0]) == 2
        # appeared イベントは1バッチ（2行）
        event_rows = [r for batch in inserts["listing_events"] for r in batch]
        assert sorted(e["event_type"] for e in event_rows) == ["appeared", "appeared"]
        # price_history は1バッチ（2行）
        ph_rows = [r for batch in inserts["price_history"] for r in batch]
        assert len(ph_rows) == 2

    def test_grace_period_removal_batched(self):
        """閾値到達の欠落物件: removed イベントが記録され summary に反映される。"""
        from supabase_sync import _sync_source_listings

        old_ik = "既存マンション|2LDK|60.0|東京都江東区東雲1-1|2010|None|3"
        client, upserts, inserts = self._make_client(
            existing_listing_rows=[{"id": 50, "identity_key": old_ik, "is_active": True}],
            existing_source_rows=[{"id": 9, "listing_id": 50, "source": "suumo",
                                   "price_man": 6000, "is_active": True,
                                   "consecutive_misses": 1}],
        )

        # 既存物件はバッチに含まれず、別の新規1件のみスクレイプされたケース
        # （バッチ完全空のときは安全のため grace period 自体が走らない仕様）
        items = [self._make_item("新規マンション", 5000, "https://example.com/new")]
        summary = _sync_source_listings(client, items, "suumo", "chuko")

        assert summary["removed"] == 1
        event_rows = [r for batch in inserts["listing_events"] for r in batch]
        assert sorted(e["event_type"] for e in event_rows) == ["appeared", "removed"]

    def test_empty_batch_skips_grace_period(self):
        """スクレイプ0件のときは grace period を実行しない（フェイルセーフ維持）。"""
        from supabase_sync import _sync_source_listings

        old_ik = "既存マンション|2LDK|60.0|東京都江東区東雲1-1|2010|None|3"
        client, upserts, inserts = self._make_client(
            existing_listing_rows=[{"id": 50, "identity_key": old_ik, "is_active": True}],
            existing_source_rows=[{"id": 9, "listing_id": 50, "source": "suumo",
                                   "price_man": 6000, "is_active": True,
                                   "consecutive_misses": 1}],
        )
        summary = _sync_source_listings(client, [], "suumo", "chuko")
        assert summary["removed"] == 0
        assert inserts["listing_events"] == []
