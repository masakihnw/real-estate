"""rehouse_scraper のリストパーステスト。"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from rehouse_scraper import parse_list_html


def _card_html(line2: str, name: str = "テストマンション") -> str:
    return f"""
    <div class="property-index-card">
      <a href="/buy/mansion/bkdetail/F12345/">
        <h2 class="property-title">{name}</h2>
      </a>
      <span class="price">9,800</span>
      <div class="content">
        <p class="paragraph-body gray">港区浜松町１丁目 / 山手線 浜松町駅 徒歩5分</p>
        <p class="paragraph-body gray">{line2}</p>
      </div>
    </div>
    """


def test_parse_basic_card():
    html = f"<html><body>{_card_html('3LDK / 87.56㎡ / 2019年02月築 / 36階')}</body></html>"
    items = parse_list_html(html)
    assert len(items) == 1
    item = items[0]
    assert item.name == "テストマンション"
    assert item.price_man == 9800
    assert item.layout == "3LDK"
    assert item.area_m2 == 87.56
    assert item.built_year == 2019
    assert item.walk_min == 5
    assert item.floor_position == 36


def test_parse_floor_total_extracted_when_present():
    """「N階建」表記がある場合 floor_total が抽出される。

    floor_total が常に None だと identity_key の floor 要素が欠け、
    他ソースの同一物件との dedup 判定で誤マージの温床になる。
    """
    html = f"<html><body>{_card_html('3LDK / 87.56㎡ / 2019年02月築 / 5階 / 36階建')}</body></html>"
    items = parse_list_html(html)
    assert len(items) == 1
    assert items[0].floor_position == 5
    assert items[0].floor_total == 36


def test_parse_floor_total_only():
    """所在階なしで「N階建」だけの場合、floor_position は None のまま。"""
    html = f"<html><body>{_card_html('3LDK / 87.56㎡ / 2019年02月築 / 36階建')}</body></html>"
    items = parse_list_html(html)
    assert len(items) == 1
    assert items[0].floor_position is None
    assert items[0].floor_total == 36


def test_parse_empty_html_returns_empty():
    assert parse_list_html("<html><body></body></html>") == []


# ──────────────────────────── 区巡回ループの終端理由テスト ────────────────────────────

import threading
from types import SimpleNamespace

import pytest

import rehouse_scraper
import scraper_metrics


@pytest.fixture(autouse=True)
def _reset_metrics():
    scraper_metrics.reset()
    yield
    scraper_metrics.reset()


def _run_ward(monkeypatch, pages: dict[int, int]) -> list:
    """ページ番号→行数 の辞書で fetch/parse を偽装して _scrape_ward を実行する。"""
    monkeypatch.setattr(rehouse_scraper, "create_session", lambda: None)
    monkeypatch.setattr(rehouse_scraper, "_WARD_URL_TEMPLATE", "p=1")
    monkeypatch.setattr(rehouse_scraper, "_WARD_URL_PAGE_TEMPLATE", "p={page}")
    monkeypatch.setattr(rehouse_scraper, "fetch_list_page", lambda session, url: url)

    def fake_parse(html):
        page = int(html.split("=", 1)[1])
        return [SimpleNamespace(url=f"u{page}-{i}") for i in range(pages.get(page, 0))]

    monkeypatch.setattr(rehouse_scraper, "parse_list_html", fake_parse)
    monkeypatch.setattr(rehouse_scraper, "dump_debug_html", lambda *a: None)
    return rehouse_scraper._scrape_ward("13101", False, set(), threading.Lock())


class TestScrapeWardFinishReasons:
    def test_normal_termination(self, monkeypatch):
        results = _run_ward(monkeypatch, {1: 3, 2: 0})
        assert len(results) == 3
        entry = scraper_metrics.get_all()["rehouse"]
        assert entry["parsed"] == 3
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []

    def test_empty_ward_records_empty_page(self, monkeypatch):
        """1ページ目から0件の区は空ページ計上（全損切り分け用）。

        他の区にパース実績があればアラートなし。全区0件（=ソース全体で
        parsed=0）なら媒体全損アラートが発火する。
        """
        results = _run_ward(monkeypatch, {1: 0})
        assert results == []
        entry = scraper_metrics.get_all()["rehouse"]
        assert entry["empty_pages"] == 1
        assert entry["finish_reasons"] == {"completed": 1}
        # この時点ではソース全体で parsed=0 なので全損扱い（フェイルセーフ方向）
        assert any("媒体全損" in a for a in scraper_metrics.health_alerts())

        # 別の区でパース実績が出れば全損アラートは消える
        _run_ward(monkeypatch, {1: 3, 2: 0})
        assert scraper_metrics.health_alerts() == []

    def test_ward_limit_reached_records_safety_limit(self, monkeypatch):
        monkeypatch.setattr(rehouse_scraper, "MAX_PAGES_PER_WARD", 2)
        _run_ward(monkeypatch, {1: 2, 2: 2, 3: 2})
        entry = scraper_metrics.get_all()["rehouse"]
        assert entry["finish_reasons"] == {"safety_limit": 1}
        assert any("rehouse" in a and "safety_limit" in a for a in scraper_metrics.health_alerts())

    def test_fetch_error_records_reason(self, monkeypatch):
        monkeypatch.setattr(rehouse_scraper, "create_session", lambda: None)
        monkeypatch.setattr(rehouse_scraper, "_WARD_URL_TEMPLATE", "p=1")
        monkeypatch.setattr(rehouse_scraper, "_WARD_URL_PAGE_TEMPLATE", "p={page}")

        def boom(session, url):
            raise RuntimeError("connection reset")

        monkeypatch.setattr(rehouse_scraper, "fetch_list_page", boom)
        results = rehouse_scraper._scrape_ward("13101", False, set(), threading.Lock())
        assert results == []
        entry = scraper_metrics.get_all()["rehouse"]
        assert entry["finish_reasons"] == {"fetch_error": 1}
