"""Tests for livable_scraper."""

from __future__ import annotations

import sys
from pathlib import Path
from unittest.mock import MagicMock, patch, call

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from livable_scraper import (
    _classify_detail_item,
    _scrape_ward,
    LivableListing,
    EMPTY_PARSE_TOLERANCE,
    EMPTY_PARSE_BACKOFF_SEC,
)


class TestClassifyDetailItem:
    def test_toei_oedo_station(self):
        cat, _ = _classify_detail_item("都営大江戸線「牛込柳町」駅 徒歩3分")
        assert cat == "station"

    def test_toei_mita_station(self):
        cat, _ = _classify_detail_item("都営三田線「千石」駅 徒歩5分")
        assert cat == "station"

    def test_metro_station(self):
        cat, _ = _classify_detail_item("東京メトロ有楽町線「豊洲」駅 徒歩8分")
        assert cat == "station"

    def test_jr_station(self):
        cat, _ = _classify_detail_item("JR山手線「恵比寿」駅 徒歩10分")
        assert cat == "station"

    def test_station_without_walk(self):
        cat, _ = _classify_detail_item("東急東横線「中目黒」駅")
        assert cat == "station"

    def test_address_with_ward(self):
        cat, _ = _classify_detail_item("東京都新宿区西新宿1丁目")
        assert cat == "address"

    def test_address_with_chome(self):
        cat, _ = _classify_detail_item("港区芝浦3丁目")
        assert cat == "address"

    def test_address_ward_only(self):
        cat, _ = _classify_detail_item("世田谷区")
        assert cat == "address"

    def test_layout(self):
        cat, _ = _classify_detail_item("3LDK")
        assert cat == "layout"

    def test_area(self):
        cat, _ = _classify_detail_item("65.12m²")
        assert cat == "area"

    def test_built_year(self):
        cat, _ = _classify_detail_item("2015年3月築")
        assert cat == "built"

    def test_floor(self):
        cat, _ = _classify_detail_item("5階/地上12階建")
        assert cat == "floor"

    def test_direction(self):
        cat, _ = _classify_detail_item("南向き")
        assert cat == "direction"

    def test_empty(self):
        cat, _ = _classify_detail_item("")
        assert cat == "unknown"


_listing_counter = 0

def _make_listing(name: str = "テスト", url: str = "") -> LivableListing:
    global _listing_counter
    _listing_counter += 1
    return LivableListing(
        source="livable", url=url or f"https://example.com/{_listing_counter}", name=name,
        price_man=5000, address="東京都江東区豊洲1丁目",
        station_line="東京メトロ有楽町線「豊洲」駅 徒歩5分",
        walk_min=5, area_m2=65.0, layout="3LDK",
        built_str="2000年1月", built_year=2000,
    )


class TestScrapeWardEmptyParseRetry:
    """_scrape_ward の空パースリトライロジックのテスト"""

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    @patch("livable_scraper.parse_list_html")
    @patch("livable_scraper.apply_conditions")
    def test_single_empty_parse_retries_next_page(
        self, mock_apply, mock_parse, mock_fetch, mock_session, mock_sleep
    ):
        """1回目の空パースではbreakせず次ページに進む"""
        l1, l3 = _make_listing(), _make_listing()
        mock_parse.side_effect = [
            [l1],   # page 1: 成功
            [],     # page 2: 空パース（1回目）
            [l3],   # page 3: 成功（リカバリ）
            [],     # page 4: 空パース（1回目）
            [],     # page 5: 空パース（2回目=tolerance到達→停止）
        ]
        mock_fetch.return_value = "<html>dummy</html>"
        mock_apply.side_effect = lambda items: items

        results = _scrape_ward("13108", "江東区", apply_filter=True, limit=10)

        assert len(results) == 2
        assert mock_parse.call_count == 5

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    @patch("livable_scraper.parse_list_html")
    def test_consecutive_empty_parses_stops(
        self, mock_parse, mock_fetch, mock_session, mock_sleep
    ):
        """連続EMPTY_PARSE_TOLERANCE回の空パースで停止"""
        mock_parse.return_value = []
        mock_fetch.return_value = "<html>empty</html>"

        results = _scrape_ward("13108", "江東区", apply_filter=True, limit=10)

        assert results == []
        assert mock_parse.call_count == EMPTY_PARSE_TOLERANCE

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    @patch("livable_scraper.parse_list_html")
    def test_empty_parse_triggers_backoff_sleep(
        self, mock_parse, mock_fetch, mock_session, mock_sleep
    ):
        """空パース時にバックオフsleepが呼ばれる"""
        mock_parse.return_value = []
        mock_fetch.return_value = "<html>empty</html>"

        _scrape_ward("13108", "江東区", apply_filter=True, limit=10)

        backoff_calls = [c for c in mock_sleep.call_args_list if c == call(EMPTY_PARSE_BACKOFF_SEC)]
        assert len(backoff_calls) >= 1

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    @patch("livable_scraper.parse_list_html")
    @patch("livable_scraper.apply_conditions")
    def test_successful_parse_resets_empty_counter(
        self, mock_apply, mock_parse, mock_fetch, mock_session, mock_sleep
    ):
        """成功パースで空パースカウンタがリセットされる"""
        l2, l4 = _make_listing(), _make_listing()
        mock_parse.side_effect = [
            [],     # page 1: 空（1回目）
            [l2],   # page 2: 成功 → リセット
            [],     # page 3: 空（1回目、リセット後）
            [l4],   # page 4: 成功 → リセット
            [],     # page 5: 空（1回目）
            [],     # page 6: 空（2回目=tolerance到達→停止）
        ]
        mock_fetch.return_value = "<html>dummy</html>"
        mock_apply.side_effect = lambda items: items

        results = _scrape_ward("13108", "江東区", apply_filter=True, limit=10)

        assert len(results) == 2
        assert mock_parse.call_count == 6

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    @patch("livable_scraper.parse_list_html")
    @patch("livable_scraper.apply_conditions")
    def test_all_pages_success_no_early_stop(
        self, mock_apply, mock_parse, mock_fetch, mock_session, mock_sleep
    ):
        """全ページ正常パースなら最終ページまで取得"""
        l1, l2, l3 = _make_listing(), _make_listing(), _make_listing()
        mock_parse.side_effect = [
            [l1],   # page 1
            [l2],   # page 2
            [l3],   # page 3
            [],     # page 4: 空（1回目）
            [],     # page 5: 空（2回目→停止）
        ]
        mock_fetch.return_value = "<html>dummy</html>"
        mock_apply.side_effect = lambda items: items

        results = _scrape_ward("13108", "江東区", apply_filter=True, limit=10)

        assert len(results) == 3


class TestScrapeWardFinishReasons:
    """終端理由の scraper_metrics 記録のテスト。"""

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    @patch("livable_scraper.parse_list_html")
    def test_normal_end_records_completed(
        self, mock_parse, mock_fetch, mock_session, mock_sleep
    ):
        import scraper_metrics
        scraper_metrics.reset()
        l1 = _make_listing()
        mock_parse.side_effect = [[l1], [], []]
        mock_fetch.return_value = "<html>dummy</html>"

        _scrape_ward("13108", "江東区", apply_filter=False, limit=10)

        entry = scraper_metrics.get_all()["livable"]
        assert entry["parsed"] == 1
        assert entry["finish_reasons"] == {"completed": 1}
        assert scraper_metrics.health_alerts() == []
        scraper_metrics.reset()

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    def test_fetch_error_records_reason(self, mock_fetch, mock_session, mock_sleep):
        import scraper_metrics
        scraper_metrics.reset()
        mock_fetch.side_effect = RuntimeError("connection reset")

        _scrape_ward("13108", "江東区", apply_filter=False, limit=10)

        entry = scraper_metrics.get_all()["livable"]
        assert entry["finish_reasons"] == {"fetch_error": 1}
        scraper_metrics.reset()

    @patch("livable_scraper.time.sleep")
    @patch("livable_scraper.create_session")
    @patch("livable_scraper.fetch_list_page")
    @patch("livable_scraper.parse_list_html")
    def test_full_run_limit_records_safety_limit(
        self, mock_parse, mock_fetch, mock_session, mock_sleep
    ):
        import scraper_metrics
        scraper_metrics.reset()
        mock_parse.return_value = [_make_listing()]
        mock_fetch.return_value = "<html>dummy</html>"

        _scrape_ward("13108", "江東区", apply_filter=False, limit=2, is_full_run=True)

        entry = scraper_metrics.get_all()["livable"]
        assert entry["finish_reasons"] == {"safety_limit": 1}
        scraper_metrics.reset()


class TestParseListHtmlEmptyWarning:
    """カード0件時の警告が IPブロックを『構造変更』と断定しないことの回帰テスト。"""

    def test_blocked_page_warning_is_classified_not_structure_change(self, caplog):
        import logging
        from livable_scraper import parse_list_html
        # 正常サイズ・正規 title だがカード0件（GHA IPブロック相当）
        html = (
            "<html><head><title>中央区の中古マンション購入｜東急リバブル</title></head>"
            "<body>" + ("x" * 6000) + "</body></html>"
        )
        # realestate ロガーは propagate=False のため caplog ハンドラを直接アタッチする
        rlog = logging.getLogger("realestate")
        rlog.addHandler(caplog.handler)
        old_level = rlog.level
        rlog.setLevel(logging.WARNING)
        try:
            items = parse_list_html(html)
        finally:
            rlog.removeHandler(caplog.handler)
            rlog.setLevel(old_level)
        assert items == []
        msg = caplog.text
        # 旧来の誤断定文言を出さない
        assert "HTML構造が変わった可能性があります" not in msg
        # 分類カテゴリを含む正確な診断を出す
        assert "blocked_or_changed" in msg
