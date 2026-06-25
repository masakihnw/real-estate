"""scraping_runs 記録ヘルパーの純関数テスト。

sync 側の per-source summary を scraping_runs テーブル行へ変換する純関数と、
ラン ID 解決ロジックを固定する（DB 不要・ネットワーク I/O なし）。
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from supabase_sync import (  # noqa: E402
    _record_scraping_runs,
    build_scraping_run_rows,
    resolve_run_id,
)


class TestResolveRunId:
    def test_uses_github_run_id_with_attempt(self) -> None:
        env = {"GITHUB_RUN_ID": "123456", "GITHUB_RUN_ATTEMPT": "2"}
        assert resolve_run_id(env) == "gha-123456-2"

    def test_github_run_id_defaults_attempt_to_1(self) -> None:
        env = {"GITHUB_RUN_ID": "123456"}
        assert resolve_run_id(env) == "gha-123456-1"

    def test_falls_back_to_local_timestamp(self) -> None:
        now = datetime(2026, 6, 25, 3, 4, 5, tzinfo=timezone.utc)
        assert resolve_run_id({}, now=now) == "local-20260625T030405Z"

    def test_blank_github_run_id_falls_back(self) -> None:
        now = datetime(2026, 6, 25, 3, 4, 5, tzinfo=timezone.utc)
        assert resolve_run_id({"GITHUB_RUN_ID": ""}, now=now) == "local-20260625T030405Z"


class TestBuildScrapingRunRows:
    def test_maps_summary_fields(self) -> None:
        summaries = {
            "suumo": {"new": 21, "reappeared": 1, "updated": 3, "removed": 2, "unchanged": 42},
        }
        rows = build_scraping_run_rows(summaries, "gha-1-1", "chuko")
        assert rows == [
            {
                "run_id": "gha-1-1",
                "source": "suumo",
                "property_type": "chuko",
                "new_count": 21,
                "reappeared_count": 1,
                "updated_count": 3,
                "removed_count": 2,
                "unchanged_count": 42,
            }
        ]

    def test_missing_keys_default_to_zero(self) -> None:
        rows = build_scraping_run_rows({"athome": {"new": 5}}, "r1", "chuko")
        assert rows[0]["reappeared_count"] == 0
        assert rows[0]["updated_count"] == 0
        assert rows[0]["removed_count"] == 0
        assert rows[0]["unchanged_count"] == 0
        assert rows[0]["new_count"] == 5

    def test_sorted_by_source_for_deterministic_order(self) -> None:
        summaries = {"suumo": {"new": 1}, "athome": {"new": 2}, "homes": {"new": 3}}
        rows = build_scraping_run_rows(summaries, "r1", "chuko")
        assert [r["source"] for r in rows] == ["athome", "homes", "suumo"]

    def test_empty_summaries_returns_empty(self) -> None:
        assert build_scraping_run_rows({}, "r1", "chuko") == []

    def test_counts_coerced_to_int(self) -> None:
        rows = build_scraping_run_rows({"suumo": {"new": True, "removed": 0}}, "r1", "chuko")
        assert rows[0]["new_count"] == 1
        # int() を通したことを正確に検証（bool は int サブクラスなので type で判定）
        assert type(rows[0]["new_count"]) is int


class _StubExecute:
    def execute(self) -> None:
        return None


class _StubTable:
    def __init__(self, record: dict) -> None:
        self._record = record

    def upsert(self, rows: list[dict], *, on_conflict: str, returning: str) -> _StubExecute:
        self._record["rows"] = rows
        self._record["on_conflict"] = on_conflict
        return _StubExecute()


class _StubClient:
    def __init__(self) -> None:
        self.record: dict = {}

    def table(self, name: str) -> _StubTable:
        self.record["table"] = name
        return _StubTable(self.record)


class TestRecordScrapingRuns:
    def test_upserts_rows_with_composite_conflict(self) -> None:
        client = _StubClient()
        n = _record_scraping_runs(
            client,
            {"suumo": {"new": 3}, "athome": {"new": 0}},
            run_id="r1",
            property_type="chuko",
        )
        assert n == 2
        assert client.record["table"] == "scraping_runs"
        assert client.record["on_conflict"] == "run_id,source,property_type"
        assert [r["source"] for r in client.record["rows"]] == ["athome", "suumo"]
        assert all(r["run_id"] == "r1" for r in client.record["rows"])

    def test_empty_summaries_skips_upsert(self) -> None:
        client = _StubClient()
        n = _record_scraping_runs(client, {}, run_id="r1", property_type="chuko")
        assert n == 0
        assert "rows" not in client.record
