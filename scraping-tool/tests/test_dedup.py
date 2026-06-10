"""Tests for dedupe_listings all-None entry merging."""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from main import dedupe_listings


def _listing(
    name: str,
    layout: str = "",
    area_m2: float | None = None,
    price_man: int | None = None,
    floor_position: int | None = None,
    address: str = "東京都中央区銀座1-1",
    source: str = "suumo",
    url: str | None = None,
    built_year: int | None = None,
) -> dict:
    return {
        "name": name,
        "layout": layout,
        "area_m2": area_m2,
        "price_man": price_man,
        "floor_position": floor_position,
        "address": address,
        "source": source,
        "url": url or f"https://example.com/{name}/{source}",
        "built_year": built_year,
    }


class TestDedupeAllNoneEntries:
    def test_same_building_same_layout_all_none_merged(self):
        data = [
            _listing("テストマンション", layout="2LDK", source="suumo"),
            _listing("テストマンション", layout="2LDK", source="homes"),
        ]
        result = dedupe_listings(data)
        assert len(result) == 1
        assert result[0].get("duplicate_count", 1) >= 2

    def test_same_building_different_base_layout_not_merged(self):
        data = [
            _listing("テストマンション", layout="1K", source="suumo"),
            _listing("テストマンション", layout="3LDK", source="homes"),
        ]
        result = dedupe_listings(data)
        assert len(result) == 2

    def test_same_building_empty_layout_all_none_merged(self):
        data = [
            _listing("テストマンション", layout="", source="suumo"),
            _listing("テストマンション", layout="", source="homes"),
        ]
        result = dedupe_listings(data)
        assert len(result) == 1

    def test_many_all_none_entries_merged(self):
        data = [
            _listing("テストマンション", layout="", source=f"src{i}")
            for i in range(5)
        ]
        result = dedupe_listings(data)
        assert len(result) == 1
        assert result[0].get("duplicate_count", 1) == 5

    def test_normal_entries_still_merge(self):
        data = [
            _listing("テストマンション", area_m2=65.0, floor_position=3, price_man=5000, source="suumo"),
            _listing("テストマンション", area_m2=65.0, floor_position=3, price_man=5000, source="homes"),
        ]
        result = dedupe_listings(data)
        assert len(result) == 1

    def test_mixed_none_and_valued_not_merged(self):
        data = [
            _listing("テストマンション", layout="2LDK", source="suumo"),
            _listing("テストマンション", layout="2LDK", area_m2=65.0, price_man=5000, source="homes"),
        ]
        result = dedupe_listings(data)
        assert len(result) == 2

    def test_different_buildings_not_merged(self):
        data = [
            _listing("マンションA", layout="", source="suumo"),
            _listing("マンションB", layout="", source="suumo"),
        ]
        result = dedupe_listings(data)
        assert len(result) == 2


class TestFuzzyCrossSiteDedup:
    """2次判定（ファジーマッチング）のブロック化後の回帰テスト。

    fuzzy_identity_match の前提条件（area/built_year/住所の完全一致）で
    事前ブロック化しても、クロスサイトの表記揺れマージが機能すること。
    """

    def test_cross_site_name_variation_merged(self):
        a = _listing("パークタワー晴海", layout="3LDK", area_m2=70.5,
                     price_man=9800, source="suumo", built_year=2019,
                     address="東京都中央区晴海2-1")
        b = _listing("三井パークタワー晴海", layout="3LDK", area_m2=70.5,
                     price_man=9800, source="homes", built_year=2019,
                     address="東京都中央区晴海2-1")
        result = dedupe_listings([a, b])
        assert len(result) == 1
        assert result[0]["duplicate_count"] == 2
        assert "homes" in result[0].get("alt_sources", []) or \
               "suumo" in result[0].get("alt_sources", [])

    def test_different_area_not_merged(self):
        """面積が異なればブロックが分かれ、マージされない。"""
        a = _listing("パークタワー晴海", layout="3LDK", area_m2=70.5,
                     price_man=9800, source="suumo", built_year=2019)
        b = _listing("パークタワー晴海Z", layout="3LDK", area_m2=75.0,
                     price_man=9800, source="homes", built_year=2019)
        result = dedupe_listings([a, b])
        assert len(result) == 2

    def test_same_source_not_fuzzy_merged(self):
        """同一ソース内はファジーマージしない（別部屋の可能性）。"""
        a = _listing("パークタワー晴海", layout="3LDK", area_m2=70.5,
                     price_man=9800, source="suumo", built_year=2019,
                     floor_position=5)
        b = _listing("パークタワー晴海レジデンス", layout="3LDK", area_m2=70.5,
                     price_man=9700, source="suumo", built_year=2019,
                     floor_position=8)
        result = dedupe_listings([a, b])
        assert len(result) == 2

    def test_input_order_preserved(self):
        listings = [
            _listing(f"マンション{i}", layout="2LDK", area_m2=60.0 + i,
                     price_man=8000 + i, built_year=2010)
            for i in range(5)
        ]
        result = dedupe_listings(listings)
        assert [r["name"] for r in result] == [f"マンション{i}" for i in range(5)]
