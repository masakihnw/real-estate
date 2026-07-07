"""Tests for supabase_sync._sanitize_value."""

from __future__ import annotations

import math
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import scraper_metrics
from supabase_sync import _sanitize_value


@pytest.fixture(autouse=True)
def _no_truncation_gate(monkeypatch):
    """既存の同期テストは「完走したラン」を前提とする。
    実環境の results/scraper_metrics.json に依存しないよう打ち切り検出を無効化。"""
    monkeypatch.setattr(scraper_metrics, "source_scan_truncated", lambda source, data=None: {})
    yield


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
        enrichment_updates: list[dict] = []
        client._enrichment_updates = enrichment_updates
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
            elif name == "enrichments":
                def enr_update_side(payload, **kw):
                    m = MagicMock()

                    def in_side(col, ids):
                        enrichment_updates.append({"payload": payload, "col": col, "ids": list(ids)})
                        m2 = MagicMock()
                        m2.execute.return_value = MagicMock(data=[])
                        return m2
                    m.in_.side_effect = in_side
                    return m
                tbl.update.side_effect = enr_update_side
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

    def test_deactivation_clears_stale_images(self):
        """掲載終了物件は enrichments.suumo_images / floor_plan_images を null 化する
        （リンク切れ候補の累積＝image_urls_stale の再発防止）。"""
        from supabase_sync import _sync_source_listings

        old_ik = "既存マンション|2LDK|60.0|東京都江東区東雲1-1|2010|None|3"
        client, upserts, inserts = self._make_client(
            existing_listing_rows=[{"id": 50, "identity_key": old_ik, "is_active": True}],
            existing_source_rows=[{"id": 9, "listing_id": 50, "source": "suumo",
                                   "price_man": 6000, "is_active": True,
                                   "consecutive_misses": 1}],
        )
        items = [self._make_item("新規マンション", 5000, "https://example.com/new")]
        summary = _sync_source_listings(client, items, "suumo", "chuko")

        assert summary["removed"] == 1
        # deactivate された listing 50 に対して画像URLを null 化する update が発行される
        assert client._enrichment_updates, "enrichments の画像クリアが呼ばれていない"
        call = client._enrichment_updates[0]
        assert call["payload"] == {"suumo_images": None, "floor_plan_images": None}
        assert call["col"] == "listing_id"
        assert 50 in call["ids"]

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

    def test_truncated_run_skips_grace_period(self, monkeypatch):
        """一覧巡回が打ち切られたランでは欠落物件を deactivate しない（誤deactivate防止）。

        HOME'S 30分タイムアウト等で巡回が途中終了した場合、未巡回ページの
        物件が「見つからなかった」扱いになるため掲載終了判定を丸ごとスキップする。
        """
        from supabase_sync import _sync_source_listings

        # 既存物件が閾値到達直前（miss=1）。通常なら欠落で deactivate されるケース
        old_ik = "既存マンション|2LDK|60.0|東京都江東区東雲1-1|2010|None|3"
        client, upserts, inserts = self._make_client(
            existing_listing_rows=[{"id": 50, "identity_key": old_ik, "is_active": True}],
            existing_source_rows=[{"id": 9, "listing_id": 50, "source": "homes",
                                   "price_man": 6000, "is_active": True,
                                   "consecutive_misses": 1}],
        )
        # このランは timeout で打ち切られたと報告する
        monkeypatch.setattr(
            scraper_metrics, "source_scan_truncated",
            lambda source, data=None: {"timeout": 1} if source == "homes" else {},
        )
        items = [self._make_item("新規マンション", 5000, "https://example.com/new")]
        summary = _sync_source_listings(client, items, "homes", "chuko")

        assert summary["removed"] == 0, "打ち切りランで欠落物件が deactivate されている"
        event_rows = [r for batch in inserts["listing_events"] for r in batch]
        assert "removed" not in [e["event_type"] for e in event_rows]


class TestResolveMergedRedirect:
    """_resolve_merged_redirect: 統合済み tombstone の identity_key 一致を統合先 id に解決する。"""

    def test_no_match_returns_none(self):
        from supabase_sync import _resolve_merged_redirect

        assert _resolve_merged_redirect("未知|3LDK|70.0|港区1|2010|5", {}) is None

    def test_unmerged_listing_returns_none(self):
        from supabase_sync import _resolve_merged_redirect

        db = {"通常|3LDK|70.0|港区1|2010|5": (100, True, None)}
        assert _resolve_merged_redirect("通常|3LDK|70.0|港区1|2010|5", db) is None

    def test_tombstone_resolves_to_canonical(self):
        from supabase_sync import _resolve_merged_redirect

        db = {
            "junk名|3LDK|70.0|港区1|2010|5": (200, False, 100),
            "正規名|3LDK|70.0|港区1|2010|5": (100, True, None),
        }
        assert _resolve_merged_redirect("junk名|3LDK|70.0|港区1|2010|5", db) == 100

    def test_chain_follows_to_final_canonical(self):
        """A→B→C のチェーンは最終統合先 C に解決される。"""
        from supabase_sync import _resolve_merged_redirect

        db = {
            "ikA": (1, False, 2),
            "ikB": (2, False, 3),
            "ikC": (3, True, None),
        }
        assert _resolve_merged_redirect("ikA", db) == 3

    def test_cycle_terminates(self):
        """A→B→A の循環でも max_depth で必ず停止する。"""
        from supabase_sync import _resolve_merged_redirect

        db = {
            "ikA": (1, False, 2),
            "ikB": (2, False, 1),
        }
        result = _resolve_merged_redirect("ikA", db)
        assert result in (1, 2)

    def test_dangling_pointer_returns_last_resolved(self):
        """統合先が削除済み（id が DB に無い）でもポインタ先 id を返す。"""
        from supabase_sync import _resolve_merged_redirect

        db = {"junk": (200, False, 999)}
        assert _resolve_merged_redirect("junk", db) == 999


class TestMergedTombstoneSync:
    """統合済み tombstone の蘇生防止（merged_into リダイレクト）の統合テスト。"""

    _helper = TestSyncSourceListingsIntegration()

    def _make_item(self, name: str, price: int, url: str) -> dict:
        return self._helper._make_item(name, price, url)

    def _make_client(self, existing_listing_rows, existing_source_rows):
        return self._helper._make_client(existing_listing_rows, existing_source_rows)

    def _ik(self, item: dict) -> str:
        from report_utils import identity_key_str
        return identity_key_str(item)

    def test_tombstone_not_reactivated(self):
        """tombstone の ik に一致する掲載は listings upsert に含まれない（蘇生しない）。"""
        from supabase_sync import _sync_source_listings

        junk_item = self._make_item("平置き駐車場専用使用権付", 10480, "https://example.com/junk")
        canonical_item = self._make_item("クレストフォルム田町", 10480, "https://example.com/real")
        junk_ik = self._ik(junk_item)
        canonical_ik = self._ik(canonical_item)

        client, upserts, inserts = self._make_client(
            existing_listing_rows=[
                {"id": 100, "identity_key": canonical_ik, "is_active": True,
                 "merged_into": None},
                {"id": 200, "identity_key": junk_ik, "is_active": False,
                 "merged_into": 100},
            ],
            existing_source_rows=[
                {"id": 9, "listing_id": 100, "source": "suumo",
                 "price_man": 10480, "is_active": True, "consecutive_misses": 0},
            ],
        )

        summary = _sync_source_listings(
            client, [junk_item, canonical_item], "suumo", "chuko")

        # listings upsert は正規レコード1行のみ（tombstone の ik は含まれない）
        upserted_iks = [r["identity_key"] for batch in upserts["listings"] for r in batch]
        assert junk_ik not in upserted_iks
        assert canonical_ik in upserted_iks
        # 統合先がソース生存中なので listing_sources も正規分のみ
        source_lids = [r["listing_id"] for batch in upserts["listing_sources"] for r in batch]
        assert source_lids == [100]
        assert summary["removed"] == 0

    def test_tombstone_only_run_protects_canonical_from_grace(self):
        """junk掲載しか巡回されなかったランでも、統合先は掲載終了扱いにならない。"""
        from supabase_sync import _sync_source_listings

        junk_item = self._make_item("平置き駐車場専用使用権付", 10480, "https://example.com/junk")
        canonical_item = self._make_item("クレストフォルム田町", 10480, "https://example.com/real")
        junk_ik = self._ik(junk_item)
        canonical_ik = self._ik(canonical_item)

        client, upserts, inserts = self._make_client(
            existing_listing_rows=[
                {"id": 100, "identity_key": canonical_ik, "is_active": True,
                 "merged_into": None},
                {"id": 200, "identity_key": junk_ik, "is_active": False,
                 "merged_into": 100},
            ],
            existing_source_rows=[
                {"id": 9, "listing_id": 100, "source": "suumo",
                 "price_man": 10480, "is_active": True, "consecutive_misses": 1},
            ],
        )

        summary = _sync_source_listings(client, [junk_item], "suumo", "chuko")

        # リダイレクトの seen マーキングにより grace period の miss 対象にならない
        assert summary["removed"] == 0
        event_rows = [r for batch in inserts["listing_events"] for r in batch]
        assert "removed" not in [e["event_type"] for e in event_rows]

    def test_dead_canonical_source_attaches_redirect(self):
        """統合先の自前ソースが死んでいる場合、junk掲載のソースが統合先に付け替えられ復帰する。"""
        from supabase_sync import _sync_source_listings

        junk_item = self._make_item("平置き駐車場専用使用権付", 10480, "https://example.com/junk")
        canonical_item = self._make_item("クレストフォルム田町", 10480, "https://example.com/real")
        junk_ik = self._ik(junk_item)
        canonical_ik = self._ik(canonical_item)

        client, upserts, inserts = self._make_client(
            existing_listing_rows=[
                {"id": 100, "identity_key": canonical_ik, "is_active": False,
                 "merged_into": None},
                {"id": 200, "identity_key": junk_ik, "is_active": False,
                 "merged_into": 100},
            ],
            existing_source_rows=[
                {"id": 9, "listing_id": 100, "source": "suumo",
                 "price_man": 10480, "is_active": False, "consecutive_misses": 0},
            ],
        )

        _sync_source_listings(client, [junk_item], "suumo", "chuko")

        # junk掲載のソースが統合先 (id=100) に付く
        source_lids = [r["listing_id"] for batch in upserts["listing_sources"] for r in batch]
        assert source_lids == [100]
        source_urls = [r["url"] for batch in upserts["listing_sources"] for r in batch]
        assert source_urls == ["https://example.com/junk"]
        # 統合先 listing が復帰される（update(is_active=True)）
        listings_tbl = client.table("listings")
        reactivate_calls = [
            c for c in listings_tbl.update.call_args_list
            if c.args and c.args[0].get("is_active") is True
        ]
        assert reactivate_calls, "統合先の is_active=True 復帰が呼ばれていない"

    def test_fuzzy_match_only_tombstone_redirects(self):
        """完全一致なし・fuzzy一致が tombstone のみの場合、新規作成せず統合先へリダイレクト。"""
        from supabase_sync import _sync_source_listings

        # 同じ name・スペックだが floor 違いの ik（6要素 fuzzy 一致条件）を持つ tombstone
        junk_item = self._make_item("平置き駐車場専用使用権付", 10480, "https://example.com/junk")
        junk_ik = self._ik(junk_item)
        # tombstone は floor だけ異なる ik を持つ（fuzzy (C) 6要素 prefix 一致）
        tombstone_ik = junk_ik.rsplit("|", 1)[0] + "|9"
        canonical_item = self._make_item("クレストフォルム田町", 10480, "https://example.com/real")
        canonical_ik = self._ik(canonical_item)

        client, upserts, inserts = self._make_client(
            existing_listing_rows=[
                {"id": 100, "identity_key": canonical_ik, "is_active": True,
                 "merged_into": None},
                {"id": 200, "identity_key": tombstone_ik, "is_active": False,
                 "merged_into": 100},
            ],
            existing_source_rows=[
                {"id": 9, "listing_id": 100, "source": "suumo",
                 "price_man": 10480, "is_active": True, "consecutive_misses": 0},
            ],
        )

        summary = _sync_source_listings(client, [junk_item], "suumo", "chuko")

        # 新規 listing は作成されない（listings upsert 0 行）
        upserted_iks = [r["identity_key"] for batch in upserts["listings"] for r in batch]
        assert junk_ik not in upserted_iks
        assert upserted_iks == []


class _FakeUniqueViolation(Exception):
    """PostgREST の identity_key 一意制約違反(23505)を模した例外。"""

    def __init__(self) -> None:
        super().__init__(
            "duplicate key value violates unique constraint "
            '"listings_identity_key_key"')
        self.code = "23505"


class TestIsIdentityKeyConflict:
    """_is_identity_key_conflict の判定境界。"""

    def test_code_23505(self):
        from supabase_sync import _is_identity_key_conflict
        assert _is_identity_key_conflict(_FakeUniqueViolation()) is True

    def test_message_constraint_name(self):
        from supabase_sync import _is_identity_key_conflict
        assert _is_identity_key_conflict(
            Exception('... unique constraint "listings_identity_key_key" ...')) is True

    def test_unrelated_error_not_swallowed(self):
        from supabase_sync import _is_identity_key_conflict
        assert _is_identity_key_conflict(Exception("network timeout")) is False
        assert _is_identity_key_conflict(ValueError("RLS denied")) is False


class TestIdentityKeyConflictDoesNotAbortSource:
    """identity_key 付け替えが一意制約に衝突しても source 全体の同期が止まらない回帰テスト。

    回帰の起点: フォールバック付け替え UPDATE(:547) が無条件で、別レコード保持の ik に
    衝突すると 23505 を送出 → source 外側で捕捉され、その source の新規挿入が全滅していた。
    """

    _helper = TestSyncSourceListingsIntegration()

    def _make_item(self, name, price, url):
        return self._helper._make_item(name, price, url)

    def _ik(self, item):
        from report_utils import identity_key_str
        return identity_key_str(item)

    def _make_client_with_conflict(self, existing_listing_rows, conflict_ik, holder_rows,
                                   existing_source_rows=None):
        """conflict_ik への identity_key UPDATE が 23505 を送出するクライアントを作る。
        holder_rows は衝突相手の DB lookup（select identity_key=conflict_ik）の戻り。"""
        from unittest.mock import MagicMock
        client, upserts, inserts = self._helper._make_client(
            existing_listing_rows=existing_listing_rows,
            existing_source_rows=existing_source_rows or [])
        lt = client.table("listings")  # lazily 作成＆キャッシュ → 以降を augment

        def update_side(payload=None, **kw):
            m = MagicMock()
            if isinstance(payload, dict) and payload.get("identity_key") == conflict_ik:
                m.eq.return_value.execute.side_effect = _FakeUniqueViolation()
            else:
                m.eq.return_value.execute.return_value = MagicMock(data=[])
            return m
        lt.update.side_effect = update_side
        # 衝突相手のグローバル lookup（.select().eq(identity_key).limit().execute()）
        (lt.select.return_value.eq.return_value.limit.return_value
         .execute.return_value) = MagicMock(data=holder_rows)
        return client, upserts, inserts

    def test_conflict_redirects_and_other_new_listing_persists(self):
        from supabase_sync import _sync_source_listings

        # A: フォールバック候補(同prefix・floor違い)があり付け替え対象になる新規
        item_a = self._make_item("マンションA", 5000, "https://example.com/a")
        ik_a = self._ik(item_a)
        cand_ik = ik_a.rsplit("|", 1)[0] + "|9"  # 同prefix, floor だけ違い → fuzzy候補
        # B: 候補なしの純粋な新規（衝突に巻き込まれず挿入されるべき）
        item_b = self._make_item("ベツノマンションB", 8000, "https://example.com/b")
        ik_b = self._ik(item_b)

        client, upserts, _ = self._make_client_with_conflict(
            existing_listing_rows=[
                {"id": 100, "identity_key": cand_ik, "is_active": True, "merged_into": None},
            ],
            conflict_ik=ik_a,
            holder_rows=[{"id": 999, "merged_into": None}],  # ik_a を保持する active 行
        )

        # 例外を送出せず完走する（= source 全体が中断しない）
        summary = _sync_source_listings(client, [item_a, item_b], "suumo", "chuko")
        assert summary is not None

        # B は衝突に関係なく listings / listing_sources に永続する
        upserted_iks = [r["identity_key"] for batch in upserts["listings"] for r in batch]
        assert ik_b in upserted_iks, "衝突に無関係な新規 B が挿入されていない（source 中断の疑い）"
        source_urls = [r["url"] for batch in upserts["listing_sources"] for r in batch]
        assert "https://example.com/b" in source_urls

        # A は付け替えされず新規作成もされない（既存保持者へリダイレクト）
        assert ik_a not in upserted_iks
        # 衝突保持者(999)を再アクティブ化していない
        reactivate = [
            c for c in client.table("listings").update.call_args_list
            if c.args and isinstance(c.args[0], dict) and c.args[0].get("is_active") is True
        ]
        assert not reactivate
        # A のソースは統合先 999 に付け替わる
        a_src = [r for batch in upserts["listing_sources"] for r in batch
                 if r["url"] == "https://example.com/a"]
        assert a_src and all(r["listing_id"] == 999 for r in a_src)

    def test_conflict_unresolvable_skips_item_without_reactivating(self):
        """衝突相手を解決できない（lookup空=dangling相当）場合、item を upsert に流さずスキップ。

        ik を返すと phase2 upsert が衝突先（tombstone 含む）を is_active=True で蘇生し得るため、
        フェイルクローズで item をスキップすることを固定する。
        """
        from supabase_sync import _sync_source_listings

        item_a = self._make_item("マンションA", 5000, "https://example.com/a")
        ik_a = self._ik(item_a)
        cand_ik = ik_a.rsplit("|", 1)[0] + "|9"
        item_b = self._make_item("ベツノマンションB", 8000, "https://example.com/b")
        ik_b = self._ik(item_b)

        client, upserts, _ = self._make_client_with_conflict(
            existing_listing_rows=[
                {"id": 100, "identity_key": cand_ik, "is_active": True, "merged_into": None},
            ],
            conflict_ik=ik_a,
            holder_rows=[],  # 衝突相手が引けない（消失/dangling）→ redirect_id None
        )

        summary = _sync_source_listings(client, [item_a, item_b], "suumo", "chuko")
        assert summary is not None

        upserted_iks = [r["identity_key"] for batch in upserts["listings"] for r in batch]
        # A は蘇生回避のためスキップ（ik_a を upsert に流さない）
        assert ik_a not in upserted_iks
        a_src = [r for batch in upserts["listing_sources"] for r in batch
                 if r["url"] == "https://example.com/a"]
        assert a_src == []
        # B は問題なく永続
        assert ik_b in upserted_iks

    def test_reconcile_by_url_conflict_keeps_survivor_and_continues(self):
        """_reconcile_by_url の survivor 付け替えが 23505 でも source は中断せず、
        survivor は既存 ik のまま URL 収束し item が survivor に付く。"""
        from supabase_sync import _sync_source_listings

        survivor = self._make_item("サバイバーマンション", 5000, "https://example.com/u")
        survivor_ik = self._ik(survivor)
        # 同一URLだが面積ドリフトで別 ik になる再スクレイプ（URL一致で survivor に収束させたい）
        drifted = dict(survivor)
        drifted["area_m2"] = 71.5
        drifted_ik = self._ik(drifted)
        assert drifted_ik != survivor_ik

        client, upserts, _ = self._make_client_with_conflict(
            existing_listing_rows=[
                {"id": 100, "identity_key": survivor_ik, "is_active": True, "merged_into": None},
            ],
            conflict_ik=drifted_ik,  # survivor を drifted_ik へ付け替える UPDATE が衝突
            holder_rows=[{"id": 555, "merged_into": None}],
            existing_source_rows=[
                {"id": 9, "listing_id": 100, "source": "suumo", "url": "https://example.com/u",
                 "price_man": 5000, "is_active": True, "consecutive_misses": 0},
            ],
        )

        summary = _sync_source_listings(client, [drifted], "suumo", "chuko")
        assert summary is not None  # 例外で source 中断しない

        # survivor は既存 ik のまま（drifted_ik へ付け替わらない）
        upserted_iks = [r["identity_key"] for batch in upserts["listings"] for r in batch]
        assert drifted_ik not in upserted_iks
        # item は URL 一致で survivor(100) に収束する
        src = [r for batch in upserts["listing_sources"] for r in batch
               if r["url"] == "https://example.com/u"]
        assert src and all(r["listing_id"] == 100 for r in src)
