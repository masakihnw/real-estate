"""db.py の identity_key 解決と日付計算のテスト。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import db


def _listing_data(name: str = "テストマンション") -> dict:
    return {
        "name": name,
        "normalized_name": name,
        "address": "東京都千代田区1-1",
        "layout": "3LDK",
        "area_m2": 70.0,
        "built_year": 2000,
        "property_type": "chuko",
    }


class TestResolveListingIdentity:
    """resolve_listing_identity のテスト。

    旧 get_listing_by_identity_key は `get_` プレフィックスにもかかわらず
    identity_key の移行 UPDATE という副作用を持っていたため、
    副作用が明示的な名前に分離した。
    """

    def setup_method(self):
        self.conn = db.get_db(":memory:")

    def teardown_method(self):
        self.conn.close()

    def test_exact_match_returns_row_without_update(self):
        ik = "テストマンション|3LDK|70.0|東京都千代田区1-1|2000|住吉|5"
        lid = db.upsert_listing(self.conn, ik, _listing_data())

        found = db.resolve_listing_identity(self.conn, ik)

        assert found is not None
        assert found["id"] == lid
        # キーは変わらない
        row = self.conn.execute("SELECT identity_key FROM listings WHERE id = ?", (lid,)).fetchone()
        assert row["identity_key"] == ik

    def test_floor_none_fallback_migrates_key(self):
        """floor=None の既存キーは、階数あり新キーに移行される（明示的な副作用）。"""
        old_ik = "テストマンション|3LDK|70.0|東京都千代田区1-1|2000|住吉|None"
        new_ik = "テストマンション|3LDK|70.0|東京都千代田区1-1|2000|住吉|5"
        lid = db.upsert_listing(self.conn, old_ik, _listing_data())

        found = db.resolve_listing_identity(self.conn, new_ik)

        assert found is not None
        assert found["id"] == lid
        row = self.conn.execute("SELECT identity_key FROM listings WHERE id = ?", (lid,)).fetchone()
        assert row["identity_key"] == new_ik

    def test_no_match_returns_none(self):
        ik = "存在しない|3LDK|70.0|東京都千代田区1-1|2000|住吉|5"
        assert db.resolve_listing_identity(self.conn, ik) is None


class TestGetDaysOnMarket:
    def setup_method(self):
        self.conn = db.get_db(":memory:")

    def teardown_method(self):
        self.conn.close()

    def _insert_listing_with_source(self, first_seen_at: str) -> int:
        ik = "テストマンション|3LDK|70.0|東京都千代田区1-1|2000|住吉|5"
        lid = db.upsert_listing(self.conn, ik, _listing_data())
        self.conn.execute(
            """INSERT INTO listing_sources
               (listing_id, source, url, first_seen_at, last_seen_at, is_active)
               VALUES (?, 'suumo', 'https://example.com/1', ?, ?, 1)""",
            (lid, first_seen_at, first_seen_at),
        )
        return lid

    def test_aware_timestamp(self):
        lid = self._insert_listing_with_source("2026-06-01T00:00:00+09:00")
        days = db.get_days_on_market(self.conn, lid)
        assert days is not None and days >= 0

    def test_naive_timestamp_does_not_crash(self):
        """古いレコードの first_seen_at がタイムゾーンなしでも TypeError にならない。

        naive な値は JST として解釈する。
        """
        lid = self._insert_listing_with_source("2026-06-01T00:00:00")
        days = db.get_days_on_market(self.conn, lid)
        assert days is not None and days >= 0

    def test_no_source_returns_none(self):
        ik = "テストマンション|3LDK|70.0|東京都千代田区1-1|2000|住吉|5"
        lid = db.upsert_listing(self.conn, ik, _listing_data())
        assert db.get_days_on_market(self.conn, lid) is None
