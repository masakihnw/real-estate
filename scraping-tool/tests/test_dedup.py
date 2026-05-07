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
