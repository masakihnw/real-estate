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
        assert all_metrics["suumo"]["parsed"] == 150
        assert all_metrics["suumo"]["parse_failures"] == 2
        assert all_metrics["suumo"]["empty_pages"] == 1
        assert all_metrics["rehouse"]["parsed"] == 30


class TestRecordFinish:
    def test_accumulates_reasons(self):
        scraper_metrics.record_finish("athome", "completed")
        scraper_metrics.record_finish("athome", "completed")
        scraper_metrics.record_finish("athome", "waf_abort")

        entry = scraper_metrics.get_all()["athome"]
        assert entry["finish_reasons"] == {"completed": 2, "waf_abort": 1}

    def test_invalid_reason_raises(self):
        with pytest.raises(ValueError):
            scraper_metrics.record_finish("athome", "unknown_reason")

    def test_get_all_returns_copy(self):
        """get_all の戻り値を変更しても内部状態に影響しない。"""
        scraper_metrics.record_finish("homes", "timeout")
        snapshot = scraper_metrics.get_all()
        snapshot["homes"]["finish_reasons"]["timeout"] = 99
        assert scraper_metrics.get_all()["homes"]["finish_reasons"]["timeout"] == 1


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

    def test_zero_parse_with_activity_alerts(self):
        """活動記録があるのにパース0件 = 媒体全損の可能性（athome全損ケース）。"""
        for _ in range(23):
            scraper_metrics.record_finish("athome", "completed")
        scraper_metrics.record("athome", empty_pages=23)
        alerts = scraper_metrics.health_alerts()
        assert any("athome" in a and "媒体全損" in a for a in alerts)

    def test_zero_parse_without_activity_no_alert(self):
        """無効化等で一度も走っていないソースはアラートしない。"""
        assert scraper_metrics.health_alerts() == []

    def test_normal_finish_reasons_no_alert(self):
        """completed / early_exit は正常終端なのでアラートしない。"""
        scraper_metrics.record("suumo", parsed=500)
        scraper_metrics.record_finish("suumo", "completed")
        scraper_metrics.record_finish("suumo", "early_exit")
        assert scraper_metrics.health_alerts() == []

    def test_abnormal_finish_reasons_alert(self):
        """timeout / safety_limit 等は取りこぼしの可能性としてアラート。"""
        scraper_metrics.record("homes", parsed=3447)
        scraper_metrics.record_finish("homes", "timeout")
        alerts = scraper_metrics.health_alerts()
        assert len(alerts) == 1
        assert "homes" in alerts[0]
        assert "timeout" in alerts[0]
        assert "取りこぼし" in alerts[0]

    def test_safety_limit_alert(self):
        """安全上限到達（nomucom 100ページケース）は取りこぼしの可能性としてアラート。"""
        scraper_metrics.record("nomucom", parsed=4000)
        scraper_metrics.record_finish("nomucom", "safety_limit")
        alerts = scraper_metrics.health_alerts()
        assert any("nomucom" in a and "safety_limit" in a for a in alerts)

    def test_zero_parse_alert_suppresses_abnormal_finish_alert(self):
        """全損アラートが出るソースには異常終端アラートを重複して出さない。"""
        scraper_metrics.record_finish("athome", "waf_abort")
        alerts = scraper_metrics.health_alerts()
        athome_alerts = [a for a in alerts if "athome" in a]
        assert len(athome_alerts) == 1
        assert "媒体全損" in athome_alerts[0]


class TestSaveLoad:
    def test_roundtrip(self, tmp_path):
        scraper_metrics.record("suumo", parsed=60, parse_failures=40)
        target = tmp_path / "metrics.json"
        scraper_metrics.save(target)

        loaded = scraper_metrics.load(target)
        assert loaded["metrics"]["suumo"]["parsed"] == 60
        assert len(loaded["alerts"]) == 1

    def test_roundtrip_includes_finish_reasons(self, tmp_path):
        scraper_metrics.record("homes", parsed=100)
        scraper_metrics.record_finish("homes", "timeout")
        target = tmp_path / "metrics.json"
        scraper_metrics.save(target)

        loaded = scraper_metrics.load(target)
        assert loaded["metrics"]["homes"]["finish_reasons"] == {"timeout": 1}
        assert "saved_at" in loaded


class TestSourceScanTruncated:
    """掲載終了判定（grace period）のゲートに使う打ち切り検出のテスト。"""

    def _data(self, reasons: dict, saved_at: str | None = "fresh") -> dict:
        from datetime import datetime, timezone, timedelta
        if saved_at == "fresh":
            saved_at = datetime.now(timezone.utc).isoformat()
        elif saved_at == "stale":
            saved_at = (datetime.now(timezone.utc) - timedelta(hours=48)).isoformat()
        data = {"metrics": {"homes": {"parsed": 100, "finish_reasons": reasons}}, "alerts": []}
        if saved_at:
            data["saved_at"] = saved_at
        return data

    def test_timeout_detected_as_truncation(self):
        result = scraper_metrics.source_scan_truncated("homes", self._data({"timeout": 1}))
        assert result == {"timeout": 1}

    def test_normal_finish_not_truncation(self):
        result = scraper_metrics.source_scan_truncated(
            "homes", self._data({"completed": 1, "early_exit": 22}))
        assert result == {}

    def test_unknown_source_not_truncation(self):
        result = scraper_metrics.source_scan_truncated("athome", self._data({"timeout": 1}))
        assert result == {}

    def test_stale_file_does_not_gate(self, tmp_path, monkeypatch):
        """前回ラン以前の古いメトリクスで掲載終了判定が永久に止まらない。"""
        target = tmp_path / "metrics.json"
        import json
        target.write_text(json.dumps(self._data({"timeout": 1}, saved_at="stale")), encoding="utf-8")
        monkeypatch.setattr(scraper_metrics, "METRICS_PATH", target)
        assert scraper_metrics.source_scan_truncated("homes") == {}

    def test_missing_saved_at_does_not_gate(self, tmp_path, monkeypatch):
        target = tmp_path / "metrics.json"
        import json
        target.write_text(json.dumps(self._data({"timeout": 1}, saved_at=None)), encoding="utf-8")
        monkeypatch.setattr(scraper_metrics, "METRICS_PATH", target)
        assert scraper_metrics.source_scan_truncated("homes") == {}

    def test_fresh_file_gates(self, tmp_path, monkeypatch):
        target = tmp_path / "metrics.json"
        import json
        target.write_text(json.dumps(self._data({"waf_abort": 2})), encoding="utf-8")
        monkeypatch.setattr(scraper_metrics, "METRICS_PATH", target)
        assert scraper_metrics.source_scan_truncated("homes") == {"waf_abort": 2}

    def test_stale_metrics_data_arg_does_not_gate(self):
        """引数渡しでも古いデータ（saved_at が24h超）はゲートしない。"""
        stale = self._data({"timeout": 1}, saved_at="stale")
        assert scraper_metrics.source_scan_truncated("homes", stale) == {}

    def test_missing_saved_at_arg_does_not_gate(self):
        """引数渡しで saved_at 欠落のデータはゲートしない。"""
        no_ts = self._data({"timeout": 1}, saved_at=None)
        assert scraper_metrics.source_scan_truncated("homes", no_ts) == {}

    def test_load_missing_file(self, tmp_path):
        loaded = scraper_metrics.load(tmp_path / "nonexistent.json")
        assert loaded == {"metrics": {}, "alerts": []}

    def test_load_corrupt_file(self, tmp_path):
        target = tmp_path / "corrupt.json"
        target.write_text("{not json")
        loaded = scraper_metrics.load(target)
        assert loaded == {"metrics": {}, "alerts": []}
