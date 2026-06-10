"""athome_scraper の区巡回ループ（_scrape_ward_pages）のテスト。

athome が全23区0件・無警告で終わる事故（2026-06 実発生）の再発防止として、
終端理由・パース件数の記録と異常応答HTMLの保全をテストする。
"""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import athome_scraper
import scraper_metrics


@pytest.fixture(autouse=True)
def _reset_metrics():
    scraper_metrics.reset()
    yield
    scraper_metrics.reset()


@pytest.fixture(autouse=True)
def _no_dump(monkeypatch):
    """テストではHTMLダンプをファイルに書かない（呼び出しだけ記録）。"""
    calls: list[tuple[str, str, str]] = []
    monkeypatch.setattr(
        athome_scraper, "dump_debug_html",
        lambda source, label, html: calls.append((source, label, html)),
    )
    yield calls


def _row(url: str = "https://example.com/1") -> SimpleNamespace:
    return SimpleNamespace(url=url)


def _make_parse(pages: dict[int, int], monkeypatch):
    """ページ番号→行数 の辞書から parse_list_html を偽装する。"""
    def fake_parse(html):
        page = int(html)  # fetch_fn にはページ番号を文字列で返す str を渡す約束
        return [_row(f"https://example.com/{page}-{i}") for i in range(pages.get(page, 0))]
    monkeypatch.setattr(athome_scraper, "parse_list_html", fake_parse)


class TestScrapeWardPages:
    def test_normal_termination_records_completed(self, monkeypatch):
        """パース実績ありで0件ページに到達 = 正常終端。"""
        _make_parse({1: 3, 2: 2, 3: 0}, monkeypatch)
        results = athome_scraper._scrape_ward_pages(
            str, "chiyoda-city", limit=50, apply_filter=False, is_full_run=True,
        )

        assert len(results) == 5
        entry = scraper_metrics.get_all()["athome"]
        assert entry["parsed"] == 5
        assert entry["empty_pages"] == 0
        assert entry["finish_reasons"] == {"completed": 1}

    def test_zero_parse_ward_records_empty_page_and_dumps(self, monkeypatch, _no_dump):
        """1ページ目から0件の区は空ページ計上 + HTML保全（全損切り分け用）。"""
        _make_parse({1: 0}, monkeypatch)
        results = athome_scraper._scrape_ward_pages(
            str, "chuo-city", limit=50, apply_filter=False, is_full_run=True,
        )

        assert results == []
        entry = scraper_metrics.get_all()["athome"]
        assert entry["parsed"] == 0
        assert entry["empty_pages"] == 1
        assert entry["finish_reasons"] == {"completed": 1}
        assert _no_dump == [("athome", "chuo-city", "1")]

    def test_all_zero_wards_trigger_total_loss_alert(self, monkeypatch):
        """全区0件なら媒体全損アラートが発火する（E2E: ループ→health_alerts）。"""
        _make_parse({}, monkeypatch)
        for ward in ("chiyoda-city", "chuo-city", "minato-city"):
            athome_scraper._scrape_ward_pages(
                str, ward, limit=50, apply_filter=False, is_full_run=True,
            )

        alerts = scraper_metrics.health_alerts()
        assert any("athome" in a and "媒体全損" in a for a in alerts)

    def test_fetch_error_records_reason(self, monkeypatch):
        _make_parse({}, monkeypatch)

        def boom(page):
            raise RuntimeError("connection reset")

        athome_scraper._scrape_ward_pages(
            boom, "minato-city", limit=50, apply_filter=False, is_full_run=True,
        )
        entry = scraper_metrics.get_all()["athome"]
        assert entry["finish_reasons"] == {"fetch_error": 1}

    def test_empty_html_records_waf_abort(self, monkeypatch):
        _make_parse({}, monkeypatch)
        athome_scraper._scrape_ward_pages(
            lambda page: "", "shinjuku-city", limit=50, apply_filter=False, is_full_run=True,
        )
        entry = scraper_metrics.get_all()["athome"]
        assert entry["finish_reasons"] == {"waf_abort": 1}

    def test_early_exit_records_reason(self, monkeypatch):
        """連続Nページ通過0件の早期打ち切りは正常終端として記録。"""
        _make_parse({1: 2, 2: 2, 3: 2}, monkeypatch)
        monkeypatch.setattr(athome_scraper, "EARLY_EXIT_PAGES", 2)
        monkeypatch.setattr(athome_scraper, "apply_conditions", lambda rows: [])

        results = athome_scraper._scrape_ward_pages(
            str, "bunkyo-city", limit=50, apply_filter=True, is_full_run=True,
        )
        assert results == []
        entry = scraper_metrics.get_all()["athome"]
        assert entry["parsed"] == 4  # 2ページ分パース後に打ち切り
        assert entry["finish_reasons"] == {"early_exit": 1}

    def test_limit_reached_full_run_records_safety_limit(self, monkeypatch):
        """全ページ指定で安全上限に達した場合は取りこぼしの可能性として記録。"""
        _make_parse({1: 2, 2: 2}, monkeypatch)
        athome_scraper._scrape_ward_pages(
            str, "taito-city", limit=2, apply_filter=False, is_full_run=True,
        )
        entry = scraper_metrics.get_all()["athome"]
        assert entry["finish_reasons"] == {"safety_limit": 1}
        assert any("safety_limit" in a for a in scraper_metrics.health_alerts())

    def test_limit_reached_user_specified_records_completed(self, monkeypatch):
        """ユーザーが max_pages を明示した場合の上限到達は正常終端。"""
        _make_parse({1: 2, 2: 2}, monkeypatch)
        athome_scraper._scrape_ward_pages(
            str, "sumida-city", limit=2, apply_filter=False, is_full_run=False,
        )
        entry = scraper_metrics.get_all()["athome"]
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []
