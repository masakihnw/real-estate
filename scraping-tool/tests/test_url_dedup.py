"""source+URL 突合レイヤのテスト。

不変条件「同一 (source, url) は同一 listing」を検証する。
identity_key（name|layout|area|address|built_year|floor）が面積・築年・名前の
パースブレで変わっても、同一URLなら既存 listing に収束し重複を増やさないこと、
かつ階が割れている候補（=別住戸の可能性）はマージしないことを確認する。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import scraper_metrics  # noqa: E402
import pytest  # noqa: E402

from report_utils import identity_key_str  # noqa: E402
from supabase_sync import (  # noqa: E402
    _build_url_index,
    _floor_from_identity_key,
    _select_url_survivor,
    _sync_source_listings,
    _url_merge_allowed,
)
from tests.test_supabase_sync import TestSyncSourceListingsIntegration  # noqa: E402


@pytest.fixture(autouse=True)
def _no_truncation_gate(monkeypatch):
    monkeypatch.setattr(scraper_metrics, "source_scan_truncated", lambda source, data=None: {})
    yield


# --- 純関数 -----------------------------------------------------------------

class TestBuildUrlIndex:
    def test_empty_returns_empty(self):
        assert _build_url_index([]) == {}

    def test_single_url_single_listing(self):
        rows = [{"listing_id": 10, "url": "https://x/a"}]
        assert _build_url_index(rows) == {"https://x/a": [10]}

    def test_duplicate_url_collects_all_ids_sorted(self):
        rows = [
            {"listing_id": 200, "url": "https://x/a"},
            {"listing_id": 100, "url": "https://x/a"},
        ]
        assert _build_url_index(rows) == {"https://x/a": [100, 200]}

    def test_duplicate_listing_id_deduped(self):
        rows = [
            {"listing_id": 100, "url": "https://x/a"},
            {"listing_id": 100, "url": "https://x/a"},
        ]
        assert _build_url_index(rows) == {"https://x/a": [100]}

    def test_none_and_empty_url_skipped(self):
        rows = [
            {"listing_id": 1, "url": None},
            {"listing_id": 2, "url": ""},
            {"listing_id": 3, "url": "https://x/c"},
        ]
        assert _build_url_index(rows) == {"https://x/c": [3]}

    def test_none_listing_id_skipped(self):
        rows = [{"listing_id": None, "url": "https://x/a"}]
        assert _build_url_index(rows) == {}


class TestFloorFromIdentityKey:
    def test_none_input(self):
        assert _floor_from_identity_key(None) is None
        assert _floor_from_identity_key("") is None

    def test_floor_none_segment(self):
        assert _floor_from_identity_key("名|3LDK|70.0|江東区豊洲5|2000|None") is None

    def test_integer_floor(self):
        assert _floor_from_identity_key("名|3LDK|70.0|江東区豊洲5|2000|4") == 4

    def test_float_floor(self):
        assert _floor_from_identity_key("名|3LDK|70.0|江東区豊洲5|2000|4.0") == 4

    def test_garbage_floor(self):
        assert _floor_from_identity_key("名|3LDK|70.0|江東区豊洲5|2000|??") is None


class TestUrlMergeAllowed:
    def test_both_none_allows(self):
        assert _url_merge_allowed(None, None) is True

    def test_one_none_allows(self):
        assert _url_merge_allowed(4, None) is True
        assert _url_merge_allowed(None, 4) is True

    def test_same_floor_allows(self):
        assert _url_merge_allowed(4, 4) is True

    def test_different_floor_blocks(self):
        assert _url_merge_allowed(4, 9) is False


class TestSelectUrlSurvivor:
    def test_single_id(self):
        assert _select_url_survivor([100]) == (100, [])

    def test_min_id_is_survivor(self):
        survivor, excess = _select_url_survivor([300, 100, 200])
        assert survivor == 100
        assert sorted(excess) == [200, 300]


# --- 統合（_sync_source_listings 経由）---------------------------------------

class TestUrlDedupIntegration:
    """既存DBの同一URL重複が取り込み時に1本へ収束することを検証する。"""

    _helper = TestSyncSourceListingsIntegration()

    def _make_item(self, *, name, price, url, area, built, floor, layout="3LDK",
                   address="東京都江東区豊洲5"):
        return {
            "name": name, "price_man": price, "url": url, "address": address,
            "layout": layout, "area_m2": area, "built_year": built, "floor_position": floor,
        }

    def _make_client(self, listing_rows, source_rows):
        return self._helper._make_client(listing_rows, source_rows)

    def _listings_tbl(self, client):
        return client.table("listings")

    def test_same_url_diff_area_built_converges(self):
        """同一URL・同一階だが面積/築年がブレた2レコードが survivor(min id) に収束する。"""
        url = "https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_21032351/"
        a = self._make_item(name="オーベルA", price=9600, url=url, area=75.38, built=2002, floor=4)
        b = self._make_item(name="オーベルB", price=9600, url=url, area=75.83, built=2000, floor=4)
        ik_a, ik_b = identity_key_str(a), identity_key_str(b)
        assert ik_a != ik_b  # 面積/築年のブレで別キー（=増殖の原因）

        client, upserts, _ = self._make_client(
            listing_rows=[
                {"id": 100, "identity_key": ik_a, "is_active": True, "merged_into": None},
                {"id": 200, "identity_key": ik_b, "is_active": True, "merged_into": None},
            ],
            source_rows=[
                {"id": 1, "listing_id": 100, "source": "suumo", "url": url,
                 "price_man": 9600, "is_active": True, "consecutive_misses": 0},
                {"id": 2, "listing_id": 200, "source": "suumo", "url": url,
                 "price_man": 9600, "is_active": True, "consecutive_misses": 0},
            ],
        )

        # 今回のスクレイプは1掲載（同一URL）
        summary = _sync_source_listings(client, [a], "suumo", "chuko")

        # 余剰 listing (id=200) が1件だけ削除される
        assert self._listings_tbl(client).delete.call_count == 1
        # merged_into 付け替え update が survivor(=100) を指して発生
        merged_updates = [
            c for c in self._listings_tbl(client).update.call_args_list
            if c.args and "merged_into" in c.args[0]
        ]
        assert merged_updates, "merged_into tombstone 付け替えが呼ばれていない"
        assert all(c.args[0] == {"merged_into": 100} for c in merged_updates), \
            "merged_into が survivor(id=100) 以外を指している"
        # 重複が既存統合扱いになり新規としてカウントされない
        assert summary["new"] == 0

    def test_tombstone_not_selected_as_survivor(self):
        """url_index に統合済み tombstone(merged_into 付き)が混ざっても survivor に選ばれない。"""
        url = "https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_77777777/"
        item = self._make_item(name="物件", price=8000, url=url, area=70.0, built=2010, floor=5)
        canonical_ik = identity_key_str(item)
        tomb_ik = identity_key_str(
            self._make_item(name="物件旧", price=8000, url=url, area=70.9, built=2011, floor=5))

        client, upserts, _ = self._make_client(
            listing_rows=[
                # tombstone(id=50, 最小id)が merged_into=100 を持つ
                {"id": 50, "identity_key": tomb_ik, "is_active": False, "merged_into": 100},
                {"id": 100, "identity_key": canonical_ik, "is_active": True, "merged_into": None},
            ],
            source_rows=[
                {"id": 1, "listing_id": 50, "source": "suumo", "url": url,
                 "price_man": 8000, "is_active": True, "consecutive_misses": 0},
                {"id": 2, "listing_id": 100, "source": "suumo", "url": url,
                 "price_man": 8000, "is_active": True, "consecutive_misses": 0},
            ],
        )

        _sync_source_listings(client, [item], "suumo", "chuko")

        # tombstone(id=50) が survivor に選ばれていれば、正常 active な id=100 が
        # excess として削除される。tombstone を除外できていれば削除は0件。
        assert self._listings_tbl(client).delete.call_count == 0, \
            "tombstone を survivor に選び正常 listing を削除してしまった"

    def test_same_url_multiple_items_one_scan_no_third_listing(self):
        """1スクレイプ内に同一URLが面積違いで2回出ても3本目の listing を作らない。"""
        url = "https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_66666666/"
        existing = self._make_item(name="物件", price=8000, url=url, area=70.0, built=2010, floor=5)
        ex_ik = identity_key_str(existing)
        a = self._make_item(name="物件", price=8000, url=url, area=70.3, built=2010, floor=5)
        b = self._make_item(name="物件", price=8000, url=url, area=70.7, built=2010, floor=5)
        assert len({ex_ik, identity_key_str(a), identity_key_str(b)}) == 3  # 全て別キー

        client, upserts, _ = self._make_client(
            listing_rows=[
                {"id": 100, "identity_key": ex_ik, "is_active": True, "merged_into": None},
            ],
            source_rows=[
                {"id": 1, "listing_id": 100, "source": "suumo", "url": url,
                 "price_man": 8000, "is_active": True, "consecutive_misses": 0},
            ],
        )

        _sync_source_listings(client, [a, b], "suumo", "chuko")

        # listings upsert に渡る identity_key は1種類だけ（survivor の canonical_ik に固定）
        upserted_iks = {r["identity_key"] for batch in upserts["listings"] for r in batch}
        assert len(upserted_iks) == 1, f"同一URLが複数 ik で upsert された: {upserted_iks}"
        # listing_sources も1件のみ（survivor）
        source_rows = [r for batch in upserts["listing_sources"] for r in batch]
        assert len(source_rows) == 1

    def test_url_match_ignores_identity_key_drift(self):
        """既存1件と面積が違っても、同一URLなら新規作成せず既存に収束する。"""
        url = "https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_99999999/"
        existing = self._make_item(name="物件", price=8000, url=url, area=70.0, built=2010, floor=5)
        drifted = self._make_item(name="物件", price=8000, url=url, area=70.5, built=2010, floor=5)
        ik_existing = identity_key_str(existing)
        assert identity_key_str(drifted) != ik_existing

        client, upserts, _ = self._make_client(
            listing_rows=[
                {"id": 100, "identity_key": ik_existing, "is_active": True, "merged_into": None},
            ],
            source_rows=[
                {"id": 1, "listing_id": 100, "source": "suumo", "url": url,
                 "price_man": 8000, "is_active": True, "consecutive_misses": 0},
            ],
        )

        summary = _sync_source_listings(client, [drifted], "suumo", "chuko")

        # 既存1件のみなので削除は発生しない
        assert self._listings_tbl(client).delete.call_count == 0
        # 既存 listing が drifted の新キーへ付け替えられる（identity_key update）
        ik_updates = [
            c for c in self._listings_tbl(client).update.call_args_list
            if c.args and "identity_key" in c.args[0]
        ]
        assert ik_updates, "survivor の identity_key 付け替えが呼ばれていない"
        # 新規としてカウントされない（既存への収束）
        assert summary["new"] == 0

    def test_floor_split_same_url_not_merged(self):
        """同一URLでも階が割れている候補（別住戸の可能性）はマージしない。"""
        url = "https://suumo.jp/ms/chuko/tokyo/sc_koto/nc_88888888/"
        unit4 = self._make_item(name="物件", price=8000, url=url, area=70.0, built=2010, floor=4)
        unit9 = self._make_item(name="物件", price=9000, url=url, area=80.0, built=2010, floor=9)
        ik4, ik9 = identity_key_str(unit4), identity_key_str(unit9)

        client, upserts, _ = self._make_client(
            listing_rows=[
                {"id": 100, "identity_key": ik4, "is_active": True, "merged_into": None},
                {"id": 200, "identity_key": ik9, "is_active": True, "merged_into": None},
            ],
            source_rows=[
                {"id": 1, "listing_id": 100, "source": "suumo", "url": url,
                 "price_man": 8000, "is_active": True, "consecutive_misses": 0},
                {"id": 2, "listing_id": 200, "source": "suumo", "url": url,
                 "price_man": 9000, "is_active": True, "consecutive_misses": 0},
            ],
        )

        # 4F の住戸だけスクレイプ — 9F の別住戸はマージ対象外で温存される
        _sync_source_listings(client, [unit4], "suumo", "chuko")

        assert self._listings_tbl(client).delete.call_count == 0, "別階の住戸を誤って削除した"
