"""nomucom_scraper のリストパース（ゴールデン）テスト。

HTML 構造が変わってパースが崩れたことを CI で検知するための固定 fixture。
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from nomucom_scraper import parse_list_html


FIXTURE = """
<html><body>
<div class="item_resultsmall">
  <div class="item_title">
    <a class="click_R_link" href="/mansion/id/12345/">テストレジデンス豊洲</a>
  </div>
  <div class="item_resultsmall_lower">
    <table><tr>
      <td class="item_2">
        <p class="item_location">東京都江東区豊洲5丁目</p>
        <p class="item_access">東京メトロ有楽町線「豊洲」駅 徒歩7分</p>
      </td>
      <td class="item_3"><p class="item_price">9,480万円</p></td>
      <td class="item_4">75.2m<sup>2</sup><br>3LDK<br>南東</td>
      <td class="item_5">2015年3月<br>12階 / 20階建<br>総戸数150戸</td>
    </tr></table>
  </div>
</div>
</body></html>
"""


def test_parse_basic_card():
    items = parse_list_html(FIXTURE)
    assert len(items) == 1
    item = items[0]
    assert item.name == "テストレジデンス豊洲"
    assert item.url == "https://www.nomu.com/mansion/id/12345/"
    assert item.price_man == 9480
    assert item.address == "東京都江東区豊洲5丁目"
    assert item.walk_min == 7
    assert item.area_m2 == 75.2
    assert item.layout == "3LDK"
    assert item.built_year == 2015
    assert item.floor_position == 12
    assert item.floor_total == 20
    assert item.total_units == 150


def test_parse_empty_html():
    assert parse_list_html("<html><body></body></html>") == []


def test_card_without_url_skipped():
    html = '<html><body><div class="item_resultsmall"><div class="item_title"></div></div></body></html>'
    assert parse_list_html(html) == []


# ──────────────────────────── 巡回ループの終端理由テスト ────────────────────────────

import pytest

import nomucom_scraper
import scraper_metrics


@pytest.fixture(autouse=True)
def _reset_metrics():
    scraper_metrics.reset()
    yield
    scraper_metrics.reset()


def _run_scrape(monkeypatch, pages: dict[int, int], max_pages: int = 0) -> list:
    """ページ番号→行数 の辞書で fetch/parse を偽装して scrape_nomucom を実行する。"""
    from types import SimpleNamespace

    monkeypatch.setattr(nomucom_scraper, "create_session", lambda: None)
    # URL形式に依存しないよう、ページ番号だけのURLに差し替え、fetch は URL をそのまま返す
    monkeypatch.setattr(nomucom_scraper, "LIST_URL_FIRST", "page=1/")
    monkeypatch.setattr(nomucom_scraper, "LIST_URL_PAGE", "page={page}/")
    monkeypatch.setattr(nomucom_scraper, "fetch_list_page", lambda session, url: url)

    def fake_parse(html):
        page = int(html.split("=", 1)[1].rstrip("/"))
        return [SimpleNamespace(url=f"u{page}-{i}") for i in range(pages.get(page, 0))]

    monkeypatch.setattr(nomucom_scraper, "parse_list_html", fake_parse)
    monkeypatch.setattr(nomucom_scraper, "dump_debug_html", lambda *a: None)
    monkeypatch.setattr(nomucom_scraper, "EMPTY_PARSE_BACKOFF_SEC", 0)
    return list(nomucom_scraper.scrape_nomucom(max_pages=max_pages, apply_filter=False))


class TestScrapeLoopFinishReasons:
    def test_normal_termination(self, monkeypatch):
        results = _run_scrape(monkeypatch, {1: 3, 2: 2, 3: 0})
        assert len(results) == 5
        entry = scraper_metrics.get_all()["nomucom"]
        assert entry["parsed"] == 5
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []

    def test_empty_first_page_records_abort(self, monkeypatch):
        """全ページ空のときは連続2回（tolerance）試した上で全損として記録。"""
        results = _run_scrape(monkeypatch, {1: 0})
        assert results == []
        entry = scraper_metrics.get_all()["nomucom"]
        assert entry["finish_reasons"] == {"empty_parse_abort": 1}
        assert entry["empty_pages"] == 2  # EMPTY_PARSE_TOLERANCE 回分
        assert any("媒体全損" in a for a in scraper_metrics.health_alerts())

    def test_single_empty_page_does_not_abort(self, monkeypatch):
        """空ページ1回では打ち切らず、後続ページの物件を取りこぼさない。"""
        results = _run_scrape(monkeypatch, {1: 3, 2: 0, 3: 2})
        assert len(results) == 5, "空ページ1回で残ページが打ち切られている"
        entry = scraper_metrics.get_all()["nomucom"]
        assert entry["parsed"] == 5
        assert entry["empty_pages"] == 1  # 途中ギャップのみ（終端の連続空は正常終端）
        assert entry["finish_reasons"] == {"completed": 1}

    def test_safety_limit_reached_alerts(self, monkeypatch):
        """100ページちょうどで「完了」と報告していた問題: 上限到達を区別して警告する。"""
        monkeypatch.setattr(nomucom_scraper, "MAX_PAGES_SAFETY", 2)
        _run_scrape(monkeypatch, {1: 2, 2: 2, 3: 2}, max_pages=0)
        entry = scraper_metrics.get_all()["nomucom"]
        assert entry["finish_reasons"] == {"safety_limit": 1}
        assert any("nomucom" in a and "safety_limit" in a for a in scraper_metrics.health_alerts())

    def test_user_limit_no_alert(self, monkeypatch):
        _run_scrape(monkeypatch, {1: 2, 2: 2, 3: 2}, max_pages=2)
        entry = scraper_metrics.get_all()["nomucom"]
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []

    def test_fetch_error_records_reason(self, monkeypatch):
        monkeypatch.setattr(nomucom_scraper, "create_session", lambda: None)

        def boom(session, url):
            raise RuntimeError("connection reset")

        monkeypatch.setattr(nomucom_scraper, "fetch_list_page", boom)
        results = list(nomucom_scraper.scrape_nomucom(max_pages=0, apply_filter=False))
        assert results == []
        entry = scraper_metrics.get_all()["nomucom"]
        assert entry["finish_reasons"] == {"fetch_error": 1}

    def test_generator_early_close_still_records_finish(self, monkeypatch):
        """呼び出し元が break してもジェネレータの終端理由が記録される（漏れ防止）。"""
        from types import SimpleNamespace
        monkeypatch.setattr(nomucom_scraper, "create_session", lambda: None)
        monkeypatch.setattr(nomucom_scraper, "LIST_URL_FIRST", "page=1/")
        monkeypatch.setattr(nomucom_scraper, "LIST_URL_PAGE", "page={page}/")
        monkeypatch.setattr(nomucom_scraper, "fetch_list_page", lambda session, url: url)
        monkeypatch.setattr(
            nomucom_scraper, "parse_list_html",
            lambda html: [SimpleNamespace(url=f"u{i}") for i in range(5)],
        )

        gen = nomucom_scraper.scrape_nomucom(max_pages=0, apply_filter=False)
        next(gen)
        gen.close()

        entry = scraper_metrics.get_all()["nomucom"]
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []
