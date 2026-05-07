"""Tests for livable_scraper._classify_detail_item."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from livable_scraper import _classify_detail_item


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
