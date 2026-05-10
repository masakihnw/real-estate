"""Tests for the grace period logic in db.sync_scrape_results."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import db


def _make_listing(name: str = "テストマンション", floor: int | None = 5) -> dict:
    return {
        "name": name,
        "address": "東京都千代田区1-1",
        "layout": "3LDK",
        "area_m2": 70.0,
        "built_year": 2000,
        "floor_position": floor,
        "url": "https://example.com/1",
        "price_man": 5000,
        "property_type": "chuko",
    }


def _get_source_row(conn, listing_id: int, source: str) -> dict | None:
    return conn.execute(
        "SELECT * FROM listing_sources WHERE listing_id = ? AND source = ?",
        (listing_id, source),
    ).fetchone()


def _get_events(conn, listing_id: int) -> list[dict]:
    return conn.execute(
        "SELECT * FROM listing_events WHERE listing_id = ? ORDER BY id",
        (listing_id,),
    ).fetchall()


class TestGracePeriod:
    def setup_method(self):
        self.conn = db.get_db(":memory:")

    def teardown_method(self):
        self.conn.close()

    def test_single_miss_does_not_remove(self):
        listing = _make_listing()
        s1 = db.sync_scrape_results(self.conn, [listing], "suumo")
        assert s1["new"] == 1

        s2 = db.sync_scrape_results(self.conn, [], "suumo")
        assert s2["removed"] == 0

        src = _get_source_row(self.conn, 1, "suumo")
        assert src["is_active"] == 1
        assert src["consecutive_misses"] == 1

    def test_two_consecutive_misses_removes(self):
        listing = _make_listing()
        db.sync_scrape_results(self.conn, [listing], "suumo")

        db.sync_scrape_results(self.conn, [], "suumo")
        s3 = db.sync_scrape_results(self.conn, [], "suumo")
        assert s3["removed"] == 1

        src = _get_source_row(self.conn, 1, "suumo")
        assert src["is_active"] == 0
        assert src["consecutive_misses"] == 0

    def test_reappearance_resets_consecutive_misses(self):
        listing = _make_listing()
        db.sync_scrape_results(self.conn, [listing], "suumo")

        db.sync_scrape_results(self.conn, [], "suumo")
        src = _get_source_row(self.conn, 1, "suumo")
        assert src["consecutive_misses"] == 1

        db.sync_scrape_results(self.conn, [listing], "suumo")
        src = _get_source_row(self.conn, 1, "suumo")
        assert src["consecutive_misses"] == 0
        assert src["is_active"] == 1

    def test_reappearance_after_grace_records_reappeared_event(self):
        listing = _make_listing()
        db.sync_scrape_results(self.conn, [listing], "suumo")
        db.sync_scrape_results(self.conn, [], "suumo")
        db.sync_scrape_results(self.conn, [], "suumo")

        s4 = db.sync_scrape_results(self.conn, [listing], "suumo")
        assert s4["reappeared"] == 1

        events = _get_events(self.conn, 1)
        event_types = [e["event_type"] for e in events]
        assert event_types == ["appeared", "removed", "reappeared"]

    def test_no_removed_event_during_grace(self):
        listing = _make_listing()
        db.sync_scrape_results(self.conn, [listing], "suumo")
        db.sync_scrape_results(self.conn, [], "suumo")

        events = _get_events(self.conn, 1)
        event_types = [e["event_type"] for e in events]
        assert "removed" not in event_types

    def test_grace_period_env_override(self, monkeypatch):
        monkeypatch.setattr(db, "GRACE_PERIOD_RUNS", 3)

        listing = _make_listing()
        db.sync_scrape_results(self.conn, [listing], "suumo")

        db.sync_scrape_results(self.conn, [], "suumo")
        db.sync_scrape_results(self.conn, [], "suumo")
        s = db.sync_scrape_results(self.conn, [], "suumo")
        assert s["removed"] == 1

    def test_different_sources_independent_grace(self):
        listing = _make_listing()
        db.sync_scrape_results(self.conn, [listing], "suumo")
        db.sync_scrape_results(self.conn, [listing], "homes")

        db.sync_scrape_results(self.conn, [], "suumo")
        suumo_src = _get_source_row(self.conn, 1, "suumo")
        homes_src = _get_source_row(self.conn, 1, "homes")
        assert suumo_src["consecutive_misses"] == 1
        assert homes_src["consecutive_misses"] == 0
