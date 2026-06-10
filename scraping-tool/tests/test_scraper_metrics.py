"""scraper_metrics のテスト。"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import scraper_metrics


@pytest.fixture(autouse=True)
def _reset_metrics():
    scraper_metrics.reset()
    yield
    scraper_metrics.reset()


class TestRecord:
    def test_accumulates_per_source(self):
        scraper_metrics.record("suumo", parsed=100, parse_failures=2)
        scraper_metrics.record("suumo", parsed=50, empty_pages=1)
        scraper_metrics.record("rehouse", parsed=30)

        all_metrics = scraper_metrics.get_all()
        assert all_metrics["suumo"] == {"parsed": 150, "parse_failures": 2, "empty_pages": 1}
        assert all_metrics["rehouse"]["parsed"] == 30


class TestHealthAlerts:
    def test_healthy_source_no_alert(self):
        scraper_metrics.record("suumo", parsed=100, parse_failures=5)
        assert scraper_metrics.health_alerts() == []

    def test_high_failure_rate_alerts(self):
        """失敗率30%以上でHTML構造変更の可能性をアラート。"""
        scraper_metrics.record("suumo", parsed=60, parse_failures=40)
        alerts = scraper_metrics.health_alerts()
        assert len(alerts) == 1
        assert "suumo" in alerts[0]
        assert "HTML構造変更" in alerts[0]

    def test_zero_parsed_with_failures_alerts(self):
        """全件失敗（成功0）は失敗率100%でアラート。"""
        scraper_metrics.record("homes", parse_failures=10)
        alerts = scraper_metrics.health_alerts()
        assert any("homes" in a for a in alerts)

    def test_empty_pages_alerts(self):
        scraper_metrics.record("livable", parsed=100, empty_pages=3)
        alerts = scraper_metrics.health_alerts()
        assert len(alerts) == 1
        assert "botブロック" in alerts[0]

    def test_no_activity_no_alert(self):
        assert scraper_metrics.health_alerts() == []


class TestSaveLoad:
    def test_roundtrip(self, tmp_path):
        scraper_metrics.record("suumo", parsed=60, parse_failures=40)
        target = tmp_path / "metrics.json"
        scraper_metrics.save(target)

        loaded = scraper_metrics.load(target)
        assert loaded["metrics"]["suumo"]["parsed"] == 60
        assert len(loaded["alerts"]) == 1

    def test_load_missing_file(self, tmp_path):
        loaded = scraper_metrics.load(tmp_path / "nonexistent.json")
        assert loaded == {"metrics": {}, "alerts": []}

    def test_load_corrupt_file(self, tmp_path):
        target = tmp_path / "corrupt.json"
        target.write_text("{not json")
        loaded = scraper_metrics.load(target)
        assert loaded == {"metrics": {}, "alerts": []}
